import AppKit
import ImageIO
import Security
import Vision

/// The authenticators, and the one place their secrets live.
///
/// Unlike the snippets and the notes, this list is not a file in Application
/// Support. A TOTP secret is not a code — it is the key that mints codes, for
/// good, and a plain file next to `snippets.json` is exactly what a program
/// rifling through a home folder is looking for. So it goes in the system
/// keychain, all of it as one item: the keychain asks for permission per item
/// when the asking app's signature has changed, and this app is ad-hoc signed
/// and rebuilt often, so one item is one question rather than one per account.
///
/// The item is only read when the tab is first opened, not at launch. Reading
/// it is what can raise the keychain dialog, and a dialog on login — for a tab
/// the user may not open today — is a dialog nobody can connect to anything.
@MainActor
final class TOTPStore: ObservableObject {
    @Published private(set) var accounts: [TOTPAccount] = []
    /// Which one the copy button in the header of the pane reaches for. Nil
    /// means "the first", so the button works before anything has been chosen.
    @Published private(set) var primaryID: TOTPAccount.ID?
    /// Raised when the keychain answered something other than "here it is" or
    /// "there is nothing" — refused, locked, unreadable. The one state in which
    /// writing is forbidden: overwriting an item that could not be read is how
    /// a list of authenticators becomes an empty list of authenticators.
    @Published private(set) var vaultUnreadable = false

    private var loaded = false

    /// Everything, in one JSON blob. The choice of the primary rides along
    /// rather than sitting in UserDefaults, so that the whole tab is one item
    /// to back up, move to another Mac, or delete.
    private struct Vault: Codable {
        var accounts: [TOTPAccount]
        var primary: UUID?
    }

    private static let service = "com.cyclop.app"
    private static let key = "totp"

    /// The one the copy button copies.
    var primary: TOTPAccount? {
        if let primaryID, let found = accounts.first(where: { $0.id == primaryID }) { return found }
        return accounts.first
    }

    func isPrimary(_ account: TOTPAccount) -> Bool { primary?.id == account.id }

    // MARK: - Editing

    /// Adds one, or says why it could not. The returned string is a message for
    /// the pane, not a log line: everything that can go wrong here goes wrong
    /// silently otherwise — a mistyped secret produces codes that look perfectly
    /// real and are simply never accepted.
    @discardableResult
    func add(text: String, name: String) -> String? {
        guard let account = TOTP.account(from: text, name: name) else {
            return localized("Not a secret or an otpauth:// link")
        }
        loadIfNeeded()
        guard !vaultUnreadable else { return localized("The keychain item cannot be read — nothing was written") }
        // Same secret twice is a re-add, not a second account: sites hand the
        // URI out again on every "reset two-factor", and two rows that mint the
        // same code are two rows to choose between for no reason.
        accounts.removeAll { $0.secret == account.secret }
        accounts.append(account)
        if primaryID == nil { primaryID = account.id }
        save()
        return nil
    }

    func remove(_ account: TOTPAccount) {
        accounts.removeAll { $0.id == account.id }
        if primaryID == account.id { primaryID = accounts.first?.id }
        save()
    }

    func makePrimary(_ account: TOTPAccount) {
        primaryID = account.id
        save()
    }

    /// Puts the code on the pasteboard.
    ///
    /// Marked concealed, which is the convention password managers set and this
    /// app's own clipboard tab already honours: without it every code copied
    /// would land in the clipboard history, on screen, in the tab next door —
    /// a list of live second factors sitting in the open, which is the one
    /// place they must not be.
    func copy(_ account: TOTPAccount) {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([concealed, .string], owner: nil)
        pasteboard.setData(Data(), forType: concealed)
        pasteboard.setString(TOTP.code(account), forType: .string)
    }

    // MARK: - What was pasted

    /// What is on the pasteboard, if it is an authenticator.
    ///
    /// Text and picture are one button rather than two, because from where the
    /// user stands they are one action — "take the thing the site just showed
    /// me". A site offers the secret as a QR code and, in small print, as text;
    /// which of the two ends up on the pasteboard depends on which the user
    /// found first, and that is not worth making them think about.
    static func fromPasteboard() -> String? {
        let pasteboard = NSPasteboard.general
        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, TOTP.account(from: trimmed) != nil { return trimmed }
        }
        return qrPayload(on: pasteboard)
    }

    /// Reads a QR code out of a copied picture — a screenshot of the square the
    /// site puts on the screen, taken with ⌘⇧⌃4 and never saved anywhere.
    ///
    /// Vision does this offline and ships with macOS, so the tab keeps the
    /// app's bargain: no dependencies, and nothing about the secret leaves the
    /// machine. (`VNDetectBarcodesRequest` is the older of the two Vision APIs
    /// and macOS 15 marks it deprecated — it still runs, and the replacement is
    /// async-only, which would put a suspension point in the middle of a button.)
    private static func qrPayload(on pasteboard: NSPasteboard) -> String? {
        guard let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("Cyclop: cannot read the picture on the pasteboard: \(error.localizedDescription)")
            return nil
        }
        // A screenshot may hold more than one square — a page offering the code
        // for two different services, or the app's own window caught in frame.
        // The first one that is an authenticator wins; the rest are not ours.
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue else { continue }
            if payload.lowercased().hasPrefix("otpauth://") { return payload }
        }
        return nil
    }

    // MARK: - The keychain

    /// Read on the way into the tab, once. Everything after that is in memory,
    /// so the codes keep ticking without touching the keychain again.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        var query = Self.query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                vaultUnreadable = true
                return
            }
            do {
                let vault = try JSONDecoder().decode(Vault.self, from: data)
                accounts = vault.accounts
                primaryID = vault.primary
                vaultUnreadable = false
            } catch {
                // The item is there and says something that is not a vault.
                // Keep the tab empty, refuse to write, and let the pane say so
                // — the alternative is the next addition quietly replacing it.
                vaultUnreadable = true
                NSLog("Cyclop: the keychain item is not readable: \(error.localizedDescription)")
            }
        case errSecItemNotFound:
            // Nothing yet, which is what a first launch looks like. Writing is
            // safe: there is nothing to write over.
            accounts = []
            vaultUnreadable = false
        default:
            // Refused, or the keychain is locked, or the user answered "Deny"
            // to the dialog. Asking again is what the reload button is for.
            vaultUnreadable = true
            loaded = false
            NSLog("Cyclop: the keychain refused to hand over the authenticators (\(status))")
        }
    }

    /// After a refusal or a locked keychain — the pane offers this rather than
    /// making the user quit the app to try again.
    func retry() {
        loaded = false
        vaultUnreadable = false
        loadIfNeeded()
    }

    private func save() {
        guard !vaultUnreadable else {
            NSLog("Cyclop: refusing to write over a keychain item that could not be read")
            return
        }
        guard let data = try? JSONEncoder().encode(Vault(accounts: accounts, primary: primaryID)) else { return }

        let query = Self.query()
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("Cyclop: cannot write the authenticators to the keychain (\(status))")
        }
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // What Keychain Access shows in its list. Worth spending a line on:
            // an item nobody can identify is an item nobody dares delete.
            kSecAttrLabel as String: "Cyclop — authenticators",
        ]
    }
}
