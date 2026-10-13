import AppKit
import Foundation

/// Live exchange rates from [fawazahmed0/exchange-api](https://github.com/fawazahmed0/exchange-api).
///
/// The CDN is the primary host; Cloudflare Pages is the documented fallback.
/// Rates land once a day upstream, so this store refreshes every hour while
/// the tab is on and again whenever the tab is opened.
///
/// One table, always against USD: every row in the list is converted through
/// it (`amount / rates[from] * rates[to]`), so five currencies cost the same
/// single request that two did.
@MainActor
final class CurrencyStore: ObservableObject {
    struct Currency: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
        var displayCode: String { code.uppercased() }
    }

    @Published private(set) var currencies: [Currency] = []
    /// One US dollar buys this many of the key (lowercase code).
    @Published private(set) var rates: [String: Double] = [:]
    @Published private(set) var rateDate: String?
    /// When the table last arrived — what the header shows as "Updated".
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var failure: String?

    /// The currencies the user picked, in order. The local one is added after
    /// them by `rows` unless it is already here.
    @Published private(set) var pinned: [String] {
        didSet { defaults.set(pinned, forKey: listKey) }
    }

    /// The row the amount was typed into; every other row follows it.
    @Published private(set) var activeCode: String
    /// What each row shows, keyed by lowercase code.
    @Published private(set) var texts: [String: String] = [:]

    /// Currency of the region set in System Settings → Language & Region.
    /// The region, not the location: knowing where the Mac actually is would
    /// cost a Location permission, and the project asks for none it can avoid.
    let regionCurrency: String?

    /// Chosen by hand from the list, for when the region in System Settings
    /// is not where the Mac is — a trip, say. Nil follows the region.
    @Published private(set) var localOverride: String? {
        didSet { defaults.set(localOverride, forKey: localKey) }
    }

    /// The row marked with the arrow.
    var localCode: String? { localOverride ?? regionCurrency }

    /// What the tab lists: the pinned currencies, then the local one if it is
    /// not among them already.
    var rows: [String] {
        guard let localCode, !pinned.contains(localCode) else { return pinned }
        return pinned + [localCode]
    }

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 60 * 60
    private let defaults = UserDefaults.standard
    private let listKey = "currency.list"
    private let localKey = "currency.local"
    private static let base = "usd"
    /// Own session rather than `URLSession.shared`: jsDelivr sends
    /// `max-age=604800` on these files, and the shared cache would keep
    /// serving yesterday's rates for a week no matter how often we "refresh".
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static let primaryHost = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1"
    private static let fallbackHost = "https://latest.currency-api.pages.dev/v1"

    static let defaultList = ["usd", "eur", "uah", "gbp"]

    init() {
        let saved = (UserDefaults.standard.stringArray(forKey: "currency.list") ?? [])
            .map { $0.lowercased() }
        var unique: [String] = []
        for code in saved where !code.isEmpty && !unique.contains(code) { unique.append(code) }
        // Locals first: a @Published property cannot be read back until every
        // stored property has a value.
        let list = unique.isEmpty ? Self.defaultList : unique
        let first = list.first ?? Self.base
        let local = Locale.current.currency?.identifier.lowercased()
        pinned = list
        regionCurrency = (local?.isEmpty ?? true) ? nil : local
        localOverride = UserDefaults.standard.string(forKey: "currency.local")?.lowercased()
        activeCode = first
        texts = [first: "1"]
    }

    // MARK: - Lifecycle

    func start() {
        Task { await bootstrap() }
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshRates() }
        }
        // Common Mode, not just the default one: while a tracking loop or a
        // scroll is running the default mode pauses, and a currency refresh
        // queued for "in an hour" would quietly slip past.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Opening the tab always asks the network again. Skipping when a table is
    /// already in memory is what made yesterday's rates look permanent: the
    /// timer alone is not enough if the app was quit overnight.
    func refreshIfNeeded() {
        Task { await refreshRates() }
    }

    // MARK: - Amounts

    func text(for code: String) -> String {
        texts[code] ?? ""
    }

    /// Typing into a row makes it the one the others follow.
    func setText(_ text: String, for code: String) {
        activeCode = code
        texts[code] = text
        recompute()
    }

    /// Puts `code` in place of `old`. A currency already in the list trades
    /// places with it instead of appearing twice.
    ///
    /// The local row is not in `pinned`: replacing it sets the override, and
    /// a currency already in the list then simply carries the arrow.
    func replace(_ old: String, with code: String) {
        guard old != code else { return }
        guard let index = pinned.firstIndex(of: old) else {
            if old == localCode { setLocal(code) }
            return
        }
        var list = pinned
        if let existing = list.firstIndex(of: code) {
            list.swapAt(index, existing)
        } else {
            list[index] = code
        }
        pinned = list
        if activeCode == old, !list.contains(old) {
            texts[code] = texts[old]
            activeCode = code
        }
        if !rows.contains(old) { texts[old] = nil }
        recompute()
    }

    /// Nil goes back to following the region.
    func setLocal(_ code: String?) {
        let old = localCode
        localOverride = code == regionCurrency ? nil : code
        if let old, activeCode == old, !rows.contains(old), let new = localCode {
            texts[new] = texts[old]
            activeCode = new
        }
        recompute()
    }

    func filtered(query: String) -> [Currency] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return currencies }
        return currencies.filter {
            $0.code.contains(q)
                || $0.name.lowercased().contains(q)
                || (Self.countryName(for: $0.code)?.lowercased().contains(q) ?? false)
                || (Self.localizedName(for: $0.code)?.lowercased().contains(q) ?? false)
        }
    }

    func name(for code: String) -> String {
        Self.localizedName(for: code)
            ?? currencies.first { $0.code == code }?.name
            ?? code.uppercased()
    }

    /// Country a currency belongs to. Most ISO 4217 codes start with the
    /// issuing country's ISO 3166 code (USD → US, UAH → UA); the euro answers
    /// to EU. Codes that start with X (gold, SDR, the CFA francs) and crypto
    /// have no country, and get nothing rather than a wrong one.
    static func region(for code: String) -> String? {
        let upper = code.uppercased()
        guard upper.count == 3, upper.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        if upper == "EUR" { return "EU" }
        // Only real ISO 4217 codes: BTC would otherwise borrow Bhutan's flag
        // and ETH Ethiopia's.
        guard Self.isoCurrencies.contains(upper) else { return nil }
        let region = String(upper.prefix(2))
        guard Locale.Region.isoRegions.contains(where: { $0.identifier == region }) else { return nil }
        return region
    }

    private static let isoCurrencies = Set(Locale.Currency.isoCurrencies.map(\.identifier))

    static func flag(for code: String) -> String? {
        guard let region = region(for: code) else { return nil }
        let scalars = region.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// In the app's language: "Украина", "Ukraine".
    static func countryName(for code: String) -> String? {
        guard let region = region(for: code) else { return nil }
        return Locale(identifier: appLanguage).localizedString(forRegionCode: region)
    }

    /// The system's own name for the currency, in the app's language — the
    /// rate source only has English ones.
    static func localizedName(for code: String) -> String? {
        Locale(identifier: appLanguage).localizedString(forCurrencyCode: code.uppercased())
    }

    /// `amount` of `from` in `to`, through a table quoted against one base.
    /// Nil when either side is missing from the table.
    static func convert(_ amount: Double, from: String, to: String, rates: [String: Double]) -> Double? {
        guard let a = rates[from], a > 0, let b = rates[to] else { return nil }
        return amount / a * b
    }

    // MARK: - Networking

    private func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await loadCurrencies()
            try await loadRates()
            failure = nil
            recompute()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refreshRates() async {
        do {
            if currencies.isEmpty { try await loadCurrencies() }
            try await loadRates()
            failure = nil
            recompute()
        } catch {
            // Keep whatever rates we already have; only surface the error when
            // there is nothing to convert with.
            if rates.isEmpty { failure = error.localizedDescription }
        }
    }

    private func loadCurrencies() async throws {
        let data = try await fetch("currencies.min.json")
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        currencies = decoded
            .map { Currency(code: $0.key.lowercased(), name: $0.value.isEmpty ? $0.key.uppercased() : $0.value) }
            .sorted {
                if $0.code == $1.code { return false }
                // Everyday fiat first, then the long tail alphabetically.
                let a = Self.pinboard.contains($0.code)
                let b = Self.pinboard.contains($1.code)
                if a != b { return a && !b }
                if a, b {
                    return Self.pinboard.firstIndex(of: $0.code)! < Self.pinboard.firstIndex(of: $1.code)!
                }
                return $0.code < $1.code
            }
    }

    private func loadRates() async throws {
        let code = Self.base
        let data = try await fetch("currencies/\(code).min.json")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let date = object?["date"] as? String
        let table = object?[code] as? [String: Any] ?? [:]
        var parsed: [String: Double] = [code: 1]
        for (key, value) in table {
            if let number = value as? Double {
                parsed[key.lowercased()] = number
            } else if let number = value as? NSNumber {
                parsed[key.lowercased()] = number.doubleValue
            }
        }
        rates = parsed
        rateDate = date
        updatedAt = Date()
    }

    /// Tries the jsDelivr CDN first, then the Cloudflare Pages mirror the
    /// upstream README asks every client to keep as a fallback.
    private func fetch(_ endpoint: String) async throws -> Data {
        var lastError: Error?
        for host in [Self.primaryHost, Self.fallbackHost] {
            guard let url = URL(string: "\(host)/\(endpoint)") else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    // MARK: - Conversion

    /// Rewrites every row but the one being typed into. An empty or half-typed
    /// amount ("1.") leaves the others as they are, so the caret never fights
    /// a figure that is about to change anyway — except empty, which empties.
    private func recompute() {
        let source = text(for: activeCode)
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for code in rows where code != activeCode { texts[code] = "" }
            return
        }
        guard !rates.isEmpty, let amount = Self.parse(source) else { return }
        for code in rows where code != activeCode {
            if let value = Self.convert(amount, from: activeCode, to: code, rates: rates) {
                texts[code] = Self.format(value)
            } else {
                texts[code] = ""
            }
        }
    }

    /// Currencies people actually reach for, pinned to the top of the picker.
    private static let pinboard: [String] = [
        "usd", "eur", "rub", "gbp", "cny", "jpy", "chf", "try", "kzt", "uah",
        "byn", "pln", "aed", "btc", "eth", "usdt",
    ]

    /// Accepts both "1 234,56" and "1234.56". Empty and lone separators are
    /// not numbers — the other field stays put so a mid-edit "1." does not
    /// wipe the result.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var normalized = trimmed
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains(","), normalized.contains(".") {
            // "1,234.56" vs "1.234,56" — the rightmost separator is decimal.
            if let lastComma = normalized.lastIndex(of: ","),
               let lastDot = normalized.lastIndex(of: ".") {
                if lastComma > lastDot {
                    normalized = normalized.replacingOccurrences(of: ".", with: "")
                    normalized = normalized.replacingOccurrences(of: ",", with: ".")
                } else {
                    normalized = normalized.replacingOccurrences(of: ",", with: "")
                }
            }
        } else {
            normalized = normalized.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// Compact enough for the panel: whole numbers stay whole, fiat keeps a
    /// couple of decimals, tiny crypto rates keep more.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let abs = abs(value)
        let fraction: Int
        if abs >= 1000 { fraction = 2 }
        else if abs >= 1 { fraction = 2 }
        else if abs >= 0.01 { fraction = 4 }
        else if abs >= 0.0001 { fraction = 6 }
        else { fraction = 8 }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fraction
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
