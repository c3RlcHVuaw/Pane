import PaneModel
import SwiftUI

struct AccountPane: View {
    @ObservedObject var account: AccountSession
    var body: some View {
        Group {
            switch account.phase {
            case .signedIn: SignedInView(account: account)
            default: SignInView(account: account)
            }
        }
        .animation(.snappy(duration: 0.3), value: account.phase)
    }
}

private struct SignInView: View {
    @ObservedObject var account: AccountSession
    enum Mode: String, CaseIterable { case signIn = "Sign In", create = "Create Account" }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focus: Field?
    enum Field { case email, password, confirm }

    private var busy: Bool { account.phase == .busy }
    private var emailValid: Bool { email.contains("@") && email.contains(".") && !email.contains(" ") }
    private var canSubmit: Bool {
        emailValid && password.count >= 8 && (mode == .signIn || confirm == password) && !busy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    Text("Take Pane with you").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Sign in to keep your bookmarks and preferences in sync across your Macs.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .padding(.top, 18)

                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                    .onChange(of: mode) { _, _ in account.message = nil }

                VStack(spacing: 10) {
                    field(icon: "envelope.fill") {
                        TextField("Email", text: $email).textContentType(.username).focused($focus, equals: .email).accessibilityLabel("Email")
                            .onSubmit { focus = .password }
                    }
                    field(icon: "lock.fill") {
                        SecureField(mode == .create ? "Password (8+ characters)" : "Password", text: $password)
                            .textContentType(mode == .create ? .newPassword : .password).focused($focus, equals: .password)
                            .accessibilityLabel("Password")
                            .onSubmit { mode == .create ? (focus = .confirm) : submit() }
                    }
                    if mode == .create {
                        field(icon: "lock.rotation") {
                            SecureField("Repeat password", text: $confirm).focused($focus, equals: .confirm).accessibilityLabel("Repeat password").onSubmit(submit)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(width: 320)

                VStack(spacing: 8) {
                    Button(action: submit) {
                        ZStack {
                            Text(LocalizedStringKey(mode.rawValue)).opacity(busy ? 0 : 1)
                            if busy { ProgressView().controlSize(.small) }
                        }
                        .frame(width: 280, height: 22)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)

                    if let m = account.message {
                        Label(m, systemImage: "exclamationmark.circle.fill")
                            .font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).frame(width: 320)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }

                VStack(spacing: 6) {
                    Label("Your password is stored only as a salted hash on the sync server.", systemImage: "checkmark.shield.fill")
                    Label("There is no password reset yet, so keep it somewhere safe.", systemImage: "key.fill")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: mode)
            .animation(.snappy(duration: 0.25), value: account.message)
        }
        .onAppear { focus = .email }
    }

    private func field<Content: View>(icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            content().textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func submit() {
        guard canSubmit else { return }
        let e = email, p = password, m = mode
        Task {
            if m == .create { await account.register(email: e, password: p) } else { await account.signIn(email: e, password: p) }
            if account.phase == .signedIn { password = ""; confirm = "" }
        }
    }
}

private struct SignedInView: View {
    @ObservedObject var account: AccountSession
    @State private var confirmDelete = false
    @State private var deletePassword = ""
    @State private var askingPassphrase = false
    @State private var passphrase = ""
    @State private var passphraseError: String?
    @State private var busyPassphrase = false

    private func confirmPassphrase() {
        guard passphrase.count >= 8, !busyPassphrase else { return }
        busyPassphrase = true
        Task {
            let err = await account.enablePasswordSync(passphrase: passphrase)
            busyPassphrase = false
            if let err { passphraseError = err } else { passphrase = ""; askingPassphrase = false }
        }
    }

    private var initial: String { String(account.email.first.map(String.init) ?? "?").uppercased() }
    private var status: (text: String, symbol: String, color: Color) {
        if account.isSyncing { return (tr("Syncing…"), "arrow.triangle.2.circlepath", .secondary) }
        if let m = account.message { return (m, "exclamationmark.triangle.fill", .orange) }
        if let d = account.lastSync { return (String(localized: "Synced \(d.formatted(.relative(presentation: .named).locale(AppLanguage.currentLocale)))"), "checkmark.circle.fill", .green) }
        return (tr("Waiting to sync"), "clock", .secondary)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    MemberCard(name: account.email.split(separator: "@").first.map(String.init)?.capitalized ?? account.email,
                               number: account.member?.number, since: account.member?.since)
                    Spacer()
                }
                .padding(.vertical, 14)
            }
            .listRowBackground(Color.clear)
            Section {
                HStack(spacing: 14) {
                    Text(initial)
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(LinearGradient(colors: [.teal, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.email).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Label { Text(status.text) } icon: {
                            Image(systemName: status.symbol).symbolEffect(.pulse, isActive: account.isSyncing)
                        }
                        .font(.callout).foregroundStyle(status.color)
                    }
                    Spacer()
                    Button { Task { await account.syncNow() } } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(account.isSyncing)
                }
                .padding(.vertical, 6)
            }
            Section {
                Toggle(isOn: $account.syncBookmarks) { Label("Bookmarks", systemImage: "star.fill") }
                Toggle(isOn: $account.syncSettings) { Label("Preferences", systemImage: "gearshape.fill") }
                Toggle(isOn: Binding(get: { account.syncPasswords || askingPassphrase }, set: { on in
                    if on { passphrase = ""; passphraseError = nil; askingPassphrase = true } else { account.disablePasswordSync() }
                })) { Label("Passwords (end-to-end encrypted)", systemImage: "key.fill") }
            } header: { Text("Sync") } footer: {
                Text("Browsing history and open tabs stay on this Mac. Passwords are encrypted here with a passphrase only you know: the server can't read them, and neither can we.")
            }
            Section {
                Button("Sign Out") { Task { await account.signOut() } }
                Button("Delete Account…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .task { await account.refreshMember() }
        .sheet(isPresented: $askingPassphrase) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Passphrase for synced passwords", systemImage: "key.fill").font(.headline)
                Text("Choose a passphrase (at least 8 characters). On your other Macs, enter the same one. If you forget it, synced passwords can't be recovered — the ones on each Mac stay.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Passphrase", text: $passphrase).textFieldStyle(.roundedBorder).onSubmit(confirmPassphrase)
                if let e = passphraseError { Text(verbatim: e).font(.callout).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { askingPassphrase = false }.keyboardShortcut(.cancelAction)
                    Button("Turn On", action: confirmPassphrase).keyboardShortcut(.defaultAction).disabled(passphrase.count < 8 || busyPassphrase)
                }
            }
            .padding(22).frame(width: 420)
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            SecureField("Password", text: $deletePassword)
            Button("Delete Account", role: .destructive) {
                let p = deletePassword; deletePassword = ""
                Task { await account.deleteAccount(password: p) }
            }
            Button("Cancel", role: .cancel) { deletePassword = "" }
        } message: { Text("Enter your password to confirm. Synced bookmarks are removed from the server; bookmarks on this Mac are kept.") }
    }
}
