import CryptoKit
import Foundation

/// One authenticator — everything a site's QR code amounts to once decoded.
///
/// The secret is kept as bytes rather than as the base32 string it arrived in.
/// The string is a transport format: holding on to it would mean carrying a
/// second copy of the one thing in this app worth stealing, for no use.
struct TOTPAccount: Identifiable, Codable, Equatable {
    /// RFC 6238 leaves the hash open. SHA1 is what the standard defaults to and
    /// what practically every site issues; the other two exist because a few
    /// put them in the URI, and an authenticator that silently used SHA1 anyway
    /// would produce codes that are wrong without ever saying why.
    enum Algorithm: String, Codable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    let id: UUID
    /// Who issued it — "GitHub", "Google". What the row is recognised by.
    var issuer: String
    /// Which account there, usually an email.
    var account: String
    var secret: Data
    var digits: Int
    var period: Int
    var algorithm: Algorithm

    init(
        id: UUID = UUID(),
        issuer: String,
        account: String,
        secret: Data,
        digits: Int = 6,
        period: Int = 30,
        algorithm: Algorithm = .sha1
    ) {
        self.id = id
        self.issuer = issuer
        self.account = account
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// What the row is labelled with. Neither half is guaranteed to be there —
    /// a hand-typed secret may have only a name, and some issuers put the whole
    /// thing in the label with no separate issuer at all.
    var title: String {
        if !issuer.isEmpty { return issuer }
        if !account.isEmpty { return account }
        return localized("Authenticator")
    }

    /// Shown after the title when there is room, and only when it adds
    /// something: repeating the issuer as its own subtitle is noise in a row
    /// that is 26 points tall.
    var subtitle: String { issuer.isEmpty ? "" : account }
}

/// The algorithm, and the two formats a secret arrives in.
///
/// Deliberately free of any storage or UI: this is arithmetic over a key and a
/// clock, and it is the one part of the tab that can be reasoned about — and
/// checked against a known vector — without a running app.
enum TOTP {
    // MARK: - Codes

    /// The code showing right now. RFC 6238: HOTP over a counter that is simply
    /// the number of whole periods since the epoch, which is why two devices
    /// that never met agree — they are reading the same clock, not talking.
    static func code(_ account: TOTPAccount, at date: Date = Date()) -> String {
        let period = Double(max(1, account.period))
        let counter = UInt64(max(0, date.timeIntervalSince1970) / period)
        return code(account, counter: counter)
    }

    /// Seconds left on the code now showing. Drives the ring, and the ring is
    /// the only part of the tab that answers the question actually being asked
    /// at the keyboard: is there time to type this, or is it about to turn over.
    static func remaining(_ account: TOTPAccount, at date: Date = Date()) -> Double {
        let period = Double(max(1, account.period))
        let now = max(0, date.timeIntervalSince1970)
        return period - now.truncatingRemainder(dividingBy: period)
    }

    private static func code(_ account: TOTPAccount, counter: UInt64) -> String {
        var big = counter.bigEndian
        let message = withUnsafeBytes(of: &big) { Data($0) }
        let key = SymmetricKey(data: account.secret)

        let digest: Data
        switch account.algorithm {
        case .sha1: digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: digest = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: digest = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        // Dynamic truncation, RFC 4226 §5.3: the last nibble of the digest picks
        // where in it to read four bytes from, and the top bit of those is
        // dropped so the number is positive on machines that only have signed
        // integers. The offset can be at most 15 and every digest here is at
        // least 20 bytes, so the read is always inside.
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let truncated = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])

        let digits = min(max(account.digits, 6), 8)
        let modulus: UInt32 = digits == 8 ? 100_000_000 : (digits == 7 ? 10_000_000 : 1_000_000)
        // Padded, because a code with a leading zero is still that many digits
        // long and a field that expects six will not take five.
        return String(format: "%0\(digits)u", truncated % modulus)
    }

    // MARK: - Reading a secret

    /// Turns whatever was pasted into an account, or gives up.
    ///
    /// Two shapes arrive in practice and both are accepted, because which one a
    /// site hands over is not the user's choice: the full `otpauth://` URI that
    /// sits behind the QR code, and the bare base32 secret printed under it for
    /// people typing it in by hand. The URI carries the name and the parameters;
    /// the bare secret carries nothing, so `name` stands in for the label there.
    static func account(from text: String, name: String = "") -> TOTPAccount? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("otpauth://") {
            return fromURI(trimmed, fallbackName: name)
        }
        guard let secret = base32(trimmed) else { return nil }
        return TOTPAccount(issuer: name.trimmingCharacters(in: .whitespaces), account: "", secret: secret)
    }

    /// `otpauth://totp/Issuer:account?secret=…&issuer=…&digits=…&period=…&algorithm=…`
    private static func fromURI(_ text: String, fallbackName: String) -> TOTPAccount? {
        guard let components = URLComponents(string: text) else { return nil }
        // `hotp` is the counter-based sibling and is not the same thing: its
        // codes advance on use rather than on the clock, so showing one here
        // would be a code that looks live and is not. Refused rather than
        // guessed at.
        guard components.host?.lowercased() == "totp" else { return nil }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let found = items.first { $0.name.lowercased() == name }?.value
            return (found?.isEmpty ?? true) ? nil : found
        }

        guard let raw = value("secret"), let secret = base32(raw) else { return nil }

        // URLComponents hands back the path already percent-decoded, which is
        // what the label needs — issuers escape both the colon and the spaces.
        var label = components.path
        if label.hasPrefix("/") { label.removeFirst() }
        var issuer = ""
        var account = label.trimmingCharacters(in: .whitespaces)
        if let colon = label.firstIndex(of: ":") {
            issuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        // The query parameter wins over the label when both are there: the spec
        // says they should agree, and where they do not it is the label that has
        // been mangled by whoever assembled the URI.
        if let queried = value("issuer") { issuer = queried }
        if issuer.isEmpty, account.isEmpty { issuer = fallbackName.trimmingCharacters(in: .whitespaces) }

        let algorithm = TOTPAccount.Algorithm(rawValue: (value("algorithm") ?? "SHA1").uppercased()) ?? .sha1
        return TOTPAccount(
            issuer: issuer,
            account: account,
            secret: secret,
            digits: Int(value("digits") ?? "") ?? 6,
            period: Int(value("period") ?? "") ?? 30,
            algorithm: algorithm
        )
    }

    /// RFC 4648 base32 — the alphabet every site hands a secret out in, chosen
    /// there because it survives being read aloud and retyped.
    ///
    /// Padding, spaces and the hyphens sites insert for legibility are dropped
    /// rather than rejected: what gets pasted is whatever was on the screen,
    /// and refusing "JBSW Y3DP" for its space would be refusing the format the
    /// secret was actually presented in. Anything outside the alphabet is a
    /// different matter and fails, because a wrong secret produces wrong codes
    /// silently and forever.
    static func base32(_ string: String) -> Data? {
        var bits = 0
        var accumulator: UInt32 = 0
        var out = Data()
        for character in string.uppercased() {
            if character == "=" || character == "-" || character.isWhitespace { continue }
            guard let value = alphabet[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        return out.isEmpty ? nil : out
    }

    private static let alphabet: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".enumerated() {
            table[character] = UInt8(index)
        }
        return table
    }()
}
