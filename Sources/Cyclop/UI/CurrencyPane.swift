import SwiftUI

/// The currencies the user keeps, one per row, all converted from whichever
/// row was typed into last — the shape of a pocket converter rather than a
/// pair. Two to five rows: five is what the standard body holds.
///
/// A click on the amount focuses it. A click on the flag and code opens the
/// list of currencies for that row: pick one to put it there instead, or take
/// the row out at the top of the list. Below the rows, while there is room,
/// a last row adds a currency through the same list.
struct CurrencyPane: View {
    @ObservedObject var currencies: CurrencyStore
    @Binding var wantsKeyboard: Bool

    private enum Field: Hashable {
        case row(String)
        case search
    }

    /// What the open list is for: another currency in this row, or a new row.
    private enum Picking: Equatable {
        case replace(String)
        case add
    }

    @FocusState private var focused: Field?
    @State private var picking: Picking?
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
                ForEach(currencies.codes, id: \.self) { code in
                    row(code)
                }
                if currencies.canAdd {
                    addRow
                }
            }
        }
    }

    private func open(_ what: Picking) {
        query = ""
        picking = what
        if wantsKeyboard { focused = .search }
    }

    private func row(_ code: String) -> some View {
        let isActive = code == currencies.activeCode

        return HStack(spacing: 8) {
            Button {
                open(.replace(code))
            } label: {
                HStack(spacing: 7) {
                    Text(CurrencyStore.flag(for: code) ?? "")
                        .font(.system(size: 15))
                        .frame(width: 20)
                    Text(code.uppercased())
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .foregroundStyle(Theme.secondary)
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
            // The empty space around the figure focuses it. Behind the field
            // and not over the whole row: a tap gesture on the row also fired
            // for the flag, and took the focus back from the search field the
            // flag had just opened.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focused = .row(code) }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Theme.surfaceHover : Theme.surface)
        )
    }

    /// Same height as a currency row, but quieter: an outline rather than a
    /// fill, so it reads as room for one more and not as a row with no value.
    private var addRow: some View {
        Button {
            open(.add)
        } label: {
            // Just the plus, on the left where the flags are: the tooltip
            // says what it adds. Brighter than the other quiet things in the
            // panel, since it is the only way to a new row.
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 20)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.surface, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
        .help(localized("Add currency"))
    }

    // MARK: - Picker

    private func picker(for what: Picking) -> some View {
        let selected: String? = if case .replace(let code) = what { code } else { nil }
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
                        if let selected, query.isEmpty, currencies.canRemove {
                            removeRow(selected)
                        }
                        ForEach(matches) { currency in
                            Button {
                                choose(currency.code, for: what)
                            } label: {
                                pickerRow(
                                    currency,
                                    isSelected: currency.code == selected,
                                    isListed: currencies.codes.contains(currency.code)
                                )
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
    private func pickerRow(_ currency: CurrencyStore.Currency, isSelected: Bool, isListed: Bool) -> some View {
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
            // Already a row in the tab: picking it swaps the two rows when
            // replacing, and does nothing when adding.
            if isSelected || isListed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? .white : Theme.tertiary)
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

    /// Takes the row out, first in the list it opened, so the one action
    /// that is not "pick a currency" does not have to be hunted for. Absent
    /// when two rows are left: one currency is not a conversion.
    private func removeRow(_ code: String) -> some View {
        Button {
            currencies.remove(code)
            closePicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18)
                Text(localized("Remove"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.red.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
    }

    private func choose(_ code: String, for what: Picking) {
        switch what {
        case .replace(let old): currencies.replace(old, with: code)
        case .add: currencies.add(code)
        }
        closePicker()
    }

    private func closePicker() {
        picking = nil
        query = ""
        if wantsKeyboard { focused = .row(currencies.activeCode) }
    }
}
