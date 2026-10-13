import SwiftUI

/// The authenticator tab.
///
/// Shaped around the one move it exists for: the site asked for a code, and it
/// is wanted in the field within a second or two. So the account used most sits
/// in a row of its own at the top with a copy button next to it — one hover and
/// one click, without reading a list — and the rest are below, each a click
/// away. The list is the fallback; the top row is the tab.
struct TOTPPane: View {
    @ObservedObject var totp: TOTPStore
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the add fields can follow it.
    @Binding var wantsKeyboard: Bool

    private enum Field { case name, secret }

    @FocusState private var focused: Field?
    @State private var isAdding = false
    @State private var draftName = ""
    @State private var draftSecret = ""
    /// What went wrong with the last addition, in words meant for the user. A
    /// mistyped secret is the failure worth naming out loud: it produces codes
    /// that look exactly right and are refused forever.
    @State private var problem: String?
    /// Set when the fields were filled from the pasteboard, so the row can say
    /// where the secret came from instead of appearing to invent it.
    @State private var tookFromPasteboard = false
    @State private var justCopied = false
    /// How many accounts the last import brought in, while that is still worth
    /// saying. Only ever shown above one: a single addition announces itself by
    /// appearing in the list, a dozen appearing at once does not.
    @State private var importedCount = 0

    var body: some View {
        VStack(spacing: 6) {
            // The editor is deliberately outside the timeline below. A view
            // rebuilt once a second rebuilds the text fields with it, and a
            // rebuilt field loses the caret — which in a field being typed into
            // means the first letter is also the last one that lands.
            if isAdding {
                editor
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    primaryRow(now: timeline.date)
                }
            }
            if totp.vaultUnreadable { unreadableNotice }
            if let problem { problemNotice(problem) }
            if importedCount > 1 { importedNotice(importedCount) }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                list(now: timeline.date)
            }
        }
        .padding(.top, 2)
        // Read on the way in, not at launch: this is what can raise the
        // keychain dialog, and a dialog at login belongs to nothing the user
        // did. Harmless on every later visit — it only ever runs once.
        .onAppear { totp.loadIfNeeded() }
        .onChange(of: wantsKeyboard) { _, wants in
            guard wants else {
                focused = nil
                return
            }
            if isAdding { focused = draftSecret.isEmpty ? .secret : .name }
        }
        .animation(Theme.contentAnimation, value: isAdding)
    }

    // MARK: - The one that gets copied

    /// The top row. Everything in it is about one account, and the button on
    /// the right is the point of the tab.
    @ViewBuilder
    private func primaryRow(now: Date) -> some View {
        HStack(spacing: 8) {
            if let account = totp.primary {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                Text(account.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                CodeText(account: account, now: now, hidden: hides(account), size: 14)
                PeriodRing(account: account, now: now)
                Spacer(minLength: 6)
                Button { copy(account) } label: {
                    // The label changes rather than a message appearing
                    // elsewhere: the answer to "did that copy" belongs on the
                    // thing that was pressed.
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(justCopied ? Color.green : Color.white)
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.surfaceHover)
                        )
                }
                .buttonStyle(.plain)
                .help(localized("Copy the code"))
            } else {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                Text("Nothing here yet — add with +")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 6)
            }

            Button { beginAdding() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Add an authenticator"))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - Adding

    /// Takes the place of the top row rather than sitting above it — the pane
    /// is two rows tall in a panel that never resizes, and the other one is the
    /// list.
    private var editor: some View {
        HStack(spacing: 6) {
            TextField(localized("Name"), text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .padding(.horizontal, 7)
                .frame(width: 96, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .name)
                .onSubmit { commit() }

            // One field for both shapes a secret arrives in. Splitting them
            // into "link" and "code" would be asking the user to classify what
            // they pasted, which is a question about our parser, not about them.
            SecureField(localized("Secret or otpauth:// link"), text: $draftSecret)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .secret)
                .onSubmit { commit() }

            // The secret field is a SecureField, so a successful paste shows
            // up in it as a row of dots — indistinguishable from a failed one.
            // The button itself carries the answer instead.
            Button { takeFromPasteboard() } label: {
                Image(systemName: tookFromPasteboard ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tookFromPasteboard ? Color.green : Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Take the link or the QR screenshot from the clipboard"))

            Button { commit() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(draftSecret.isEmpty ? Theme.tertiary : Color.green)
            }
            .buttonStyle(.plain)
            .disabled(draftSecret.isEmpty)

            Button { cancelAdding() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surfaceHover)
        )
        // Asked for here rather than where the editor is switched on: at that
        // moment this field is not in the hierarchy yet, and a focus request
        // aimed at a view that does not exist is simply dropped.
        .onAppear { focused = draftSecret.isEmpty ? .secret : .name }
        .onKeyPress(.escape) {
            cancelAdding()
            return .handled
        }
    }

    /// The refusal to write is only honest if it is said out loud — a log line
    /// is where refusals go to be unread.
    private var unreadableNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.85))
            Text("The keychain did not open — click to ask again; nothing is overwritten")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { totp.retry() }
    }

    private func importedNotice(_ count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.85))
            Text(localized("Added: %d", count))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func problemNotice(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.85))
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - List

    @ViewBuilder
    private func list(now: Date) -> some View {
        if totp.accounts.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                if !isAdding, !totp.vaultUnreadable {
                    Text("Paste an otpauth:// link, or copy the QR and press +")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(totp.accounts) { account in
                        TOTPRow(
                            account: account,
                            now: now,
                            totp: totp,
                            privacy: privacy,
                            hidden: hides(account)
                        )
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Doing things

    private func hides(_ account: TOTPAccount) -> Bool {
        privacy.hides(.totp, "totp.\(account.id)")
    }

    private func copy(_ account: TOTPAccount) {
        totp.copy(account)
        flash($justCopied)
    }

    /// Opening the editor already looks at the pasteboard.
    ///
    /// By the time somebody presses + they have almost always just copied the
    /// link or taken a shot of the QR square — that is what sent them here. So
    /// the field arrives filled and the press that follows is the confirmation,
    /// not the paste. Nothing is added without that press.
    private func beginAdding() {
        draftName = ""
        draftSecret = ""
        problem = nil
        tookFromPasteboard = false
        isAdding = true
        wantsKeyboard = true
        takeFromPasteboard(quietly: true)
    }

    private func takeFromPasteboard(quietly: Bool = false) {
        guard let found = TOTPStore.fromPasteboard() else {
            if !quietly { problem = localized("Nothing on the clipboard that looks like an authenticator") }
            return
        }
        draftSecret = found
        tookFromPasteboard = true
        problem = nil
        // The link carries its own name, so the caret goes to the field that is
        // still empty — and a bare secret has no name at all, which is the one
        // thing that then has to be typed.
        focused = TOTP.account(from: found)?.issuer.isEmpty == false ? .secret : .name
    }

    private func cancelAdding() {
        isAdding = false
        draftName = ""
        draftSecret = ""
        problem = nil
        wantsKeyboard = false
    }

    private func commit() {
        guard !draftSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let failure = totp.add(text: draftSecret, name: draftName) {
            problem = failure
            return
        }
        // Read before the editor closes, because closing it clears the drafts
        // and this number is the only trace a bulk import leaves.
        let count = totp.imported
        // Out of the editor rather than straight into another one: adding an
        // authenticator is a thing done once per site, unlike a snippet, and
        // what is wanted next is the code.
        cancelAdding()
        if count > 1 {
            importedCount = count
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { importedCount = 0 }
        }
    }
}

// MARK: - Row

private struct TOTPRow: View {
    let account: TOTPAccount
    let now: Date
    @ObservedObject var totp: TOTPStore
    @ObservedObject var privacy: PrivacyMode
    let hidden: Bool

    @State private var hovering = false
    @State private var justCopied = false
    /// Whether the cross has been pressed once already.
    ///
    /// The only two-step control in the panel, and it earns the exception. A
    /// deleted note is a sentence to retype and a deleted snippet is an address
    /// to look up again; a deleted authenticator is a secret that exists in one
    /// place and now does not — the account behind it is reachable again only
    /// through whatever recovery the site offers, if it offers one. A stray
    /// click on a row of controls that appear on hover must not be able to do
    /// that.
    @State private var armed = false

    private var isPrimary: Bool { totp.isPrimary(account) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : (isPrimary ? "star.fill" : "key.fill"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    justCopied ? Color.green : (isPrimary ? Color.yellow.opacity(0.85) : Theme.tertiary)
                )
                .frame(width: 14)

            Text(account.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            // The account is what tells two rows of the same issuer apart, and
            // two Google accounts is the ordinary case rather than the odd one.
            if !account.subtitle.isEmpty {
                Text(account.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            CodeText(account: account, now: now, hidden: hidden, size: 12)
            PeriodRing(account: account, now: now)

            // Only under the pointer: a column of stars and crosses would
            // compete with the codes for the glance the tab exists to serve.
            if hovering {
                if privacy.covers(.totp) {
                    RevealEye(hidden: hidden) { privacy.toggle("totp.\(account.id)") }
                }
                if !isPrimary {
                    Button { totp.makePrimary(account) } label: {
                        Image(systemName: "star")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localized("Copy this one with the button above"))
                }
                Button {
                    if armed {
                        totp.remove(account)
                    } else {
                        armed = true
                    }
                } label: {
                    Image(systemName: armed ? "trash.fill" : "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(armed ? Color.red.opacity(0.9) : Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(armed
                    ? localized("Press again — a deleted secret cannot be brought back")
                    : localized("Delete"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if !inside { armed = false }
        }
        .onTapGesture {
            totp.copy(account)
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
        .animation(Theme.contentAnimation, value: armed)
    }
}

// MARK: - Pieces

/// The code, or the dust standing in for it.
///
/// Width is fixed from the number of digits rather than left to the text: the
/// digits change every period, and a row that re-lays itself out because a 1
/// became an 8 is a row that twitches once every thirty seconds.
private struct CodeText: View {
    let account: TOTPAccount
    let now: Date
    let hidden: Bool
    let size: CGFloat

    private var digits: Int { min(max(account.digits, 6), 8) }
    private var width: CGFloat { CGFloat(digits) * size * 0.63 + 7 }

    var body: some View {
        Group {
            if hidden {
                SpoilerField(seed: UInt64(bitPattern: Int64(account.id.hashValue)))
                    .frame(height: size - 2)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    // Announced rather than described: a screen reader must not
                    // be the hole in a feature about not showing things.
                    .accessibilityLabel(Text(localized("Hidden")))
            } else {
                Text(Self.grouped(TOTP.code(account, at: now)))
                    .font(.system(size: size, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    // Copying the panel's own text is not how a code gets out of
                    // here — the button is — and a half-selected code carried to
                    // a field by hand is a code typed wrong.
                    .textSelection(.disabled)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    /// Split down the middle with a thin space. Six digits read back from the
    /// screen one group at a time; an unbroken run of six is read one digit at
    /// a time, and lost halfway.
    private static func grouped(_ code: String) -> String {
        let half = code.count / 2 + code.count % 2
        guard half > 0, half < code.count else { return code }
        let index = code.index(code.startIndex, offsetBy: half)
        return String(code[..<index]) + "\u{2009}" + String(code[index...])
    }
}

/// How much of the period is left, as a ring that empties.
///
/// The number of seconds would be more precise and less useful: what is being
/// asked at the keyboard is "is there time to type this", and an arc answers
/// that without being read. It turns amber near the end, which is the moment
/// the answer changes to "wait for the next one".
private struct PeriodRing: View {
    let account: TOTPAccount
    let now: Date

    private var remaining: Double { TOTP.remaining(account, at: now) }
    private var fraction: Double { max(0.02, min(1, remaining / Double(max(1, account.period)))) }
    private var urgent: Bool { remaining <= 5 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceHover, lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    urgent ? Color.orange.opacity(0.9) : Theme.secondary,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}
