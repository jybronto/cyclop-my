import Foundation
import Testing
@testable import Cyclop

/// Тесты на разбор экспорта Google Authenticator из нескольких QR.
///
/// Google кладёт в один QR не больше десяти аккаунтов; остальные — на
/// следующих «слайдах» экспорта. Каждый слайд — самостоятельный payload с
/// номером и общим числом QR, и именно по ним вкладка говорит, что ещё не
/// перенесено.
struct TOTPMigrationTests {

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private static func bytesField(_ number: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes
    }

    private static func varintField(_ number: UInt64, _ value: UInt64) -> [UInt8] {
        varint(number << 3) + varint(value)
    }

    /// `otpauth-migration://offline?data=…` с одним аккаунтом и полями пачки.
    private static func link(issuer: String, secret: [UInt8], index: Int, size: Int, id: Int) -> String {
        let parameters = bytesField(1, secret)
            + bytesField(2, Array("me@example.com".utf8))
            + bytesField(3, Array(issuer.utf8))
            + varintField(6, 2)
        let payload = bytesField(1, parameters)
            + varintField(2, 1)
            + varintField(3, UInt64(size))
            + varintField(4, UInt64(index))
            + varintField(5, UInt64(id))
        let base64 = Data(payload).base64EncodedString()
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "otpauth-migration://offline?data=\(encoded)"
    }

    @Test func readsBatchNumbers() {
        let text = Self.link(issuer: "GitHub", secret: [1, 2, 3, 4, 5], index: 1, size: 3, id: 777)
        #expect(TOTP.migrationBatches(in: text) == [MigrationBatch(index: 1, size: 3, id: 777)])
        #expect(TOTP.accounts(from: text).map(\.issuer) == ["GitHub"])
    }

    @Test func takesEveryLinkOnItsOwnLine() {
        let first = Self.link(issuer: "GitHub", secret: [1, 2, 3, 4, 5], index: 0, size: 2, id: 9)
        let second = Self.link(issuer: "Google", secret: [6, 7, 8, 9, 10], index: 1, size: 2, id: 9)
        let text = first + "\n" + second
        #expect(TOTP.accounts(from: text).map(\.issuer) == ["GitHub", "Google"])
        #expect(TOTP.migrationBatches(in: text).map(\.index) == [0, 1])
    }

    @Test func plainLinkIsNotABatch() {
        let text = "otpauth://totp/GitHub:me?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
        #expect(TOTP.migrationBatches(in: text).isEmpty)
        #expect(TOTP.accounts(from: text).count == 1)
    }
}
