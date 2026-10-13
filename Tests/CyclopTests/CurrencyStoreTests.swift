import Foundation
import Testing
@testable import Cyclop

/// Тесты на чистую часть `CurrencyStore`: флаг по коду валюты и пересчёт
/// через таблицу курсов к одной базе. Сеть и вкладка сюда не входят.
@MainActor
struct CurrencyStoreTests {

    @Test func flagComesFromTheCountryCode() {
        #expect(CurrencyStore.flag(for: "usd") == "🇺🇸")
        #expect(CurrencyStore.flag(for: "UAH") == "🇺🇦")
        #expect(CurrencyStore.flag(for: "gbp") == "🇬🇧")
        #expect(CurrencyStore.flag(for: "azn") == "🇦🇿")
    }

    @Test func euroHasTheFlagOfTheUnion() {
        #expect(CurrencyStore.flag(for: "eur") == "🇪🇺")
    }

    /// Ни у золота, ни у крипты страны нет — пусто лучше чужого флага.
    @Test func noCountryNoFlag() {
        #expect(CurrencyStore.flag(for: "xau") == nil)
        #expect(CurrencyStore.flag(for: "btc") == nil)
        #expect(CurrencyStore.flag(for: "eth") == nil)
        #expect(CurrencyStore.flag(for: "usdt") == nil)
    }

    @Test func convertsThroughTheBase() throws {
        let rates: [String: Double] = ["usd": 1, "eur": 0.9, "uah": 45]
        let eurToUah = try #require(CurrencyStore.convert(90, from: "eur", to: "uah", rates: rates))
        #expect(abs(eurToUah - 4500) < 0.0001)
        let usdToEur = try #require(CurrencyStore.convert(10, from: "usd", to: "eur", rates: rates))
        #expect(abs(usdToEur - 9) < 0.0001)
    }

    @Test func unknownCurrencyConvertsToNothing() {
        let rates: [String: Double] = ["usd": 1]
        #expect(CurrencyStore.convert(1, from: "usd", to: "xyz", rates: rates) == nil)
        #expect(CurrencyStore.convert(1, from: "xyz", to: "usd", rates: rates) == nil)
    }
}
