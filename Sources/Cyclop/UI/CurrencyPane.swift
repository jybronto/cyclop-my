import SwiftUI

/// The currencies the user keeps, one per row, all converted from whichever
/// row was typed into last — the shape of a pocket converter rather than a
/// pair. Five rows fit the standard body: four picked by hand and the one of
/// the Mac's region, marked with an arrow, unless it is among the four.
///
/// A click on the amount focuses it; a click on the flag and code opens the
/// list to put another currency in that row. On the local row the list also
/// offers to go back to following the region in System Settings.
struct CurrencyPane: View {
    @ObservedObject var currencies: CurrencyStore
    @Binding var wantsKeyboard: Bool

    private enum Field: Hashable {
        case row(String)
        case search
    }

    @FocusState private var focused: Field?
    /// The row whose currency is being replaced, while the list is open.
    @State private var picking: String?
    @State private var query = ""

    var body: some View {
        Group {
            if let picking {
                picker(for: picking)
            } else {
                list
            }
        }
        .padding(.top, 2)
        .onAppear {
            currencies.refreshIfNeeded()
            if wantsKeyboard { focused = .row(currencies.activeCode) }
        }
        .onChange(of: wantsKeyboard) { _, wants in
            if wants {
                focused = picking == nil ? .row(currencies.activeCode) : .search
            } else {
                focused = nil
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if let failure = currencies.failure, currencies.rates.isEmpty {
            Text(failure)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
        } else {
            VStack(spacing: 2) {
                ForEach(currencies.rows, id: \.self) { code in
                    row(code)
                }
            }
        }
    }

    private func row(_ code: String) -> some View {
        let isLocal = code == currencies.localCode
        let isActive = code == currencies.activeCode

        return HStack(spacing: 8) {
            Button {
                query = ""
                picking = code
                if wantsKeyboard { focused = .search }
            } label: {
                HStack(spacing: 7) {
                    Text(CurrencyStore.flag(for: code) ?? "")
                        .font(.system(size: 15))
                        .frame(width: 20)
                    Text(code.uppercased())
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .foregroundStyle(Theme.secondary)
                    if isLocal {
                        Image(systemName: "location.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                            .help(localized("Local currency"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .help(currencies.name(for: code))

            TextField("0", text: Binding(
                get: { currencies.text(for: code) },
                set: { currencies.setText($0, for: code) }
            ))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 17, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .tint(Theme.secondary)
            .focused($focused, equals: .row(code))
            .onKeyPress(.escape) {
                currencies.setText("", for: code)
                return .handled
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        // Simultaneous, so a click on the field itself still reaches it.
        .simultaneousGesture(TapGesture().onEnded { focused = .row(code) })
    }

    // MARK: - Picker

    private func picker(for selected: String) -> some View {
        let isLocalRow = selected == currencies.localCode && !currencies.pinned.contains(selected)
        let matches = currencies.filtered(query: query)

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                TextField(localized("Search currency"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .tint(Theme.secondary)
                    .focused($focused, equals: .search)
                    .onKeyPress(.escape) {
                        if query.isEmpty {
                            closePicker()
                        } else {
                            query = ""
                        }
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.default)
                }
                Button(localized("Done")) { closePicker() }
                    .buttonStyle(.plain)
                    .pointerStyle(.default)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surface)
            )

            if let failure = currencies.failure, currencies.currencies.isEmpty {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else if matches.isEmpty {
                Text(localized("No currencies match"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if isLocalRow, query.isEmpty {
                            automaticRow
                        }
                        ForEach(matches) { currency in
                            Button {
                                choose(currency.code, replacing: selected)
                            } label: {
                                pickerRow(currency, isSelected: currency.code == selected)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { if wantsKeyboard { focused = .search } }
    }

    /// Flag, code, country, and the currency's own name dimmed after it:
    /// people look for "Украина" as often as for "UAH".
    private func pickerRow(_ currency: CurrencyStore.Currency, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(CurrencyStore.flag(for: currency.code) ?? "")
                .font(.system(size: 13))
                .frame(width: 18)
            Text(currency.displayCode)
                .font(.system(size: 11, weight: .semibold).monospaced())
                .foregroundStyle(.white)
                .frame(width: 40, alignment: .leading)
            if let country = CurrencyStore.countryName(for: currency.code) {
                Text(country)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Text(currencies.name(for: currency.code))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Theme.surfaceHover : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Back to the region from System Settings, for the local row only.
    private var automaticRow: some View {
        Button {
            currencies.setLocal(nil)
            closePicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18)
                Text(localized("By region in System Settings"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                if let region = currencies.regionCurrency {
                    Text(region.uppercased())
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 0)
                if currencies.localOverride == nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ code: String, replacing old: String) {
        currencies.replace(old, with: code)
        closePicker()
    }

    private func closePicker() {
        picking = nil
        query = ""
        if wantsKeyboard { focused = .row(currencies.activeCode) }
    }
}
