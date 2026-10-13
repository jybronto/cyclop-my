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

    /// Turns whatever was pasted into accounts, or gives up.
    ///
    /// Three shapes arrive in practice and all are accepted, because which one
    /// a site or an app hands over is not the user's choice: the full
    /// `otpauth://` URI that sits behind a QR code, the bare base32 secret
    /// printed under it for people typing it in by hand, and the
    /// `otpauth-migration://` payload Google Authenticator writes when it is
    /// asked to hand its accounts over. The first two are one account, the
    /// third is however many were on the phone.
    ///
    /// Only the bare secret carries no name, so `name` stands in for the label
    /// there and is ignored by the other two, which bring their own.
    static func accounts(from text: String, name: String = "") -> [TOTPAccount] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lowered = trimmed.lowercased()
        // Checked before the plain `otpauth://` case and not with `hasPrefix`
        // on a shared stem: the two schemes only look alike. One is text
        // carrying a single account, the other a binary payload carrying every
        // account at once.
        if lowered.hasPrefix("otpauth-migration://") {
            return fromMigration(trimmed)
        }
        if lowered.hasPrefix("otpauth://") {
            guard let one = fromURI(trimmed, fallbackName: name) else { return [] }
            return [one]
        }
        guard let secret = base32(trimmed) else { return [] }
        return [TOTPAccount(issuer: name.trimmingCharacters(in: .whitespaces), account: "", secret: secret)]
    }

    /// For the callers that only need to know whether the text parses at all,
    /// and what the first account in it is called.
    static func account(from text: String, name: String = "") -> TOTPAccount? {
        accounts(from: text, name: name).first
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

// MARK: - Google Authenticator export

/// The export format Google Authenticator writes into its "transfer accounts"
/// QR codes: `otpauth-migration://offline?data=<base64 protobuf>`.
///
/// A different thing from `otpauth://` despite the name. That one is text and
/// carries one account; this is a binary payload carrying *all* of them, which
/// is the whole point — moving off Google Authenticator means moving a dozen
/// accounts, and doing that one re-enrolment at a time is how people give up
/// halfway and keep the phone.
///
/// Google never published a schema for it, but the wire format is protobuf and
/// the field numbers have been stable for years:
///
/// ```
/// MigrationPayload { repeated OtpParameters otp_parameters = 1; ... }
/// OtpParameters {
///     bytes  secret    = 1;   // raw bytes, not base32
///     string name      = 2;   // "Issuer:account", or just the account
///     string issuer    = 3;
///     enum   algorithm = 4;   // 1 SHA1, 2 SHA256, 3 SHA512, 4 MD5
///     enum   digits    = 5;   // 1 → six, 2 → eight
///     enum   type      = 6;   // 1 HOTP, 2 TOTP
///     int64  counter   = 7;   // HOTP only
/// }
/// ```
///
/// The period is absent because Google only ever writes 30.
extension TOTP {
    static func fromMigration(_ text: String) -> [TOTPAccount] {
        guard let payload = migrationPayload(text) else { return [] }
        return parseMigration([UInt8](payload))
    }

    /// Pulls `data=` out and un-base64s it.
    ///
    /// Read out of the raw query rather than through `queryItems`: the payload
    /// is standard base64 and contains `+` and `/`, and a `+` that arrives
    /// already decoded would be turned into a space by anything that treats the
    /// query as a form. Percent-decoding is done here, once, deliberately.
    private static func migrationPayload(_ text: String) -> Data? {
        guard let components = URLComponents(string: text),
              let raw = components.percentEncodedQueryItems?
                .first(where: { $0.name.lowercased() == "data" })?.value,
              let decoded = raw.removingPercentEncoding else { return nil }

        // Both alphabets are accepted: the standard one is what Google writes,
        // and the URL-safe one is what several exporters and QR readers hand
        // back after doing their own decoding.
        var base64 = decoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    private static func parseMigration(_ bytes: [UInt8]) -> [TOTPAccount] {
        var reader = ProtobufReader(bytes: bytes)
        var found: [TOTPAccount] = []
        while let field = reader.field() {
            // Field 1 is one account; everything else is batch bookkeeping —
            // version, batch size, batch index — which matters only to an app
            // reassembling a multi-QR export, and this one takes the QRs one at
            // a time.
            if field.number == 1, field.wire == 2 {
                guard let block = reader.lengthDelimited() else { break }
                if let account = parseParameters(block) { found.append(account) }
            } else if !reader.skip(wire: field.wire) {
                break
            }
        }
        return found
    }

    private static func parseParameters(_ bytes: [UInt8]) -> TOTPAccount? {
        var reader = ProtobufReader(bytes: bytes)
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithm = TOTPAccount.Algorithm.sha1
        var digits = 6
        var isTOTP = true

        while let field = reader.field() {
            switch (field.number, field.wire) {
            case (1, 2):
                guard let block = reader.lengthDelimited() else { return nil }
                secret = Data(block)
            case (2, 2):
                guard let block = reader.lengthDelimited() else { return nil }
                name = String(decoding: block, as: UTF8.self)
            case (3, 2):
                guard let block = reader.lengthDelimited() else { return nil }
                issuer = String(decoding: block, as: UTF8.self)
            case (4, 0):
                guard let value = reader.varint() else { return nil }
                switch value {
                case 2: algorithm = .sha256
                case 3: algorithm = .sha512
                // 4 is MD5, which this app cannot produce. Returning nil drops
                // the one account rather than the whole export — the other
                // eleven are still worth having, and a silently wrong code is
                // worse than a missing row.
                case 4: return nil
                default: algorithm = .sha1
                }
            case (5, 0):
                guard let value = reader.varint() else { return nil }
                digits = value == 2 ? 8 : 6
            case (6, 0):
                guard let value = reader.varint() else { return nil }
                // 1 is HOTP: its codes advance on use, not on the clock, so a
                // tab that ticks would show a number that looks live and is not.
                isTOTP = value != 1
            default:
                guard reader.skip(wire: field.wire) else { return nil }
            }
        }

        guard !secret.isEmpty, isTOTP else { return nil }

        // The label carries the issuer again when there is no separate field —
        // same shape as in an `otpauth://` label, same split.
        var account = name.trimmingCharacters(in: .whitespaces)
        if issuer.isEmpty, let colon = name.firstIndex(of: ":") {
            issuer = String(name[..<colon]).trimmingCharacters(in: .whitespaces)
            account = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else if !issuer.isEmpty, account.hasPrefix(issuer + ":") {
            account = String(account.dropFirst(issuer.count + 1)).trimmingCharacters(in: .whitespaces)
        }

        return TOTPAccount(
            issuer: issuer,
            account: account,
            secret: secret,
            digits: digits,
            period: 30,
            algorithm: algorithm
        )
    }
}

/// Just enough protobuf to walk the export.
///
/// Hand-written rather than pulled in: the app has no dependencies and is not
/// going to grow one for four field types. Nothing here trusts the input —
/// every read is bounds-checked and every failure returns nil, because this
/// parser is pointed at a QR code photographed off someone else's screen.
private struct ProtobufReader {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// Base-128 varint, low group first, top bit as the continuation flag.
    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            // A varint longer than ten groups cannot be a 64-bit number; it is
            // a corrupt payload walking off into the rest of the buffer.
            if shift > 63 { return nil }
        }
        return nil
    }

    /// The tag: field number and wire type packed into one varint.
    mutating func field() -> (number: Int, wire: Int)? {
        guard index < bytes.count, let key = varint() else { return nil }
        return (Int(key >> 3), Int(key & 0x07))
    }

    mutating func lengthDelimited() -> [UInt8]? {
        guard let length = varint() else { return nil }
        let end = index + Int(length)
        guard length <= UInt64(bytes.count), end <= bytes.count, end >= index else { return nil }
        defer { index = end }
        return Array(bytes[index..<end])
    }

    /// Steps over a field this parser has no use for, which is what keeps it
    /// working when Google adds one.
    mutating func skip(wire: Int) -> Bool {
        switch wire {
        case 0: return varint() != nil
        case 1: index += 8; return index <= bytes.count
        case 2: return lengthDelimited() != nil
        case 5: index += 4; return index <= bytes.count
        default: return false
        }
    }
}
