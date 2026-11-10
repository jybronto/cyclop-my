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

    // MARK: - Список

    /// Свой набор настроек на тест: настоящие настройки пользователя не
    /// читаются и не пишутся.
    private static func makeDefaults() -> UserDefaults {
        let name = "cyclop-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshInstallShowsTheDefaultList() {
        let store = CurrencyStore(defaults: Self.makeDefaults())
        #expect(store.codes == ["usd", "eur", "rub"])
    }

    /// Раньше вкладка хранила пару в двух ключах; обновление не должно
    /// молча забывать, что человек выбрал.
    @Test func anOldPairBecomesTheFirstTwoRows() {
        let defaults = Self.makeDefaults()
        defaults.set("usd", forKey: "currency.source")
        defaults.set("kzt", forKey: "currency.target")
        let store = CurrencyStore(defaults: defaults)
        #expect(store.codes == ["usd", "kzt"])
        #expect(defaults.stringArray(forKey: "currency.list") == ["usd", "kzt"])
    }

    @Test func aSavedListWinsOverAnOldPair() {
        let defaults = Self.makeDefaults()
        defaults.set(["gbp", "chf", "pln"], forKey: "currency.list")
        defaults.set("usd", forKey: "currency.source")
        defaults.set("kzt", forKey: "currency.target")
        #expect(CurrencyStore(defaults: defaults).codes == ["gbp", "chf", "pln"])
    }

    @Test func replacingWithAListedCurrencySwapsTheRows() {
        let store = CurrencyStore(defaults: Self.makeDefaults())
        store.replace("usd", with: "rub")
        #expect(store.codes == ["rub", "eur", "usd"])
    }

    @Test func removeStopsAtTwoRows() {
        let store = CurrencyStore(defaults: Self.makeDefaults())
        store.remove("rub")
        #expect(store.codes == ["usd", "eur"])
        store.remove("eur")
        #expect(store.codes == ["usd", "eur"])
    }

    @Test func addStopsAtFiveAndSkipsRepeats() {
        let store = CurrencyStore(defaults: Self.makeDefaults())
        store.add("usd")
        #expect(store.codes.count == 3)
        for code in ["gbp", "uah", "chf"] { store.add(code) }
        #expect(store.codes == ["usd", "eur", "rub", "gbp", "uah"])
    }

    /// Без курсов сумму не пересчитать, но и стирать всё из-за этого нельзя:
    /// роль активной строки переходит к той, где уже что-то написано.
    @Test func removingTheActiveRowWithoutRatesKeepsAnotherAmount() {
        let store = CurrencyStore(defaults: Self.makeDefaults())
        store.setText("100", for: "usd")
        store.setText("7", for: "eur")
        store.setText("100", for: "usd")
        store.remove("usd")
        #expect(store.activeCode == "eur")
        #expect(store.text(for: "eur") == "7")
    }

    // MARK: - Разбор суммы

    @Test func aCommaBeforeThreeDigitsIsGroupingInEnglish() {
        let en = Locale(identifier: "en")
        #expect(CurrencyStore.parse("4,141", locale: en) == 4141)
        #expect(CurrencyStore.parse("1,234,567", locale: en) == 1234567)
        #expect(CurrencyStore.parse("4,141.12", locale: en) == 4141.12)
        #expect(CurrencyStore.parse("1,5", locale: en) == 1.5)
        #expect(CurrencyStore.parse("4.141", locale: en) == 4.141)
    }

    @Test func aCommaIsTheDecimalPointInRussian() {
        let ru = Locale(identifier: "ru")
        #expect(CurrencyStore.parse("4,141", locale: ru) == 4.141)
        #expect(CurrencyStore.parse("4 141,12", locale: ru) == 4141.12)
    }
}
