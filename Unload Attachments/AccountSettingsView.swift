import SwiftUI

/// iCloud Mail account configuration with a connection test. The password is
/// kept only in the Keychain; UserDefaults stores the email address and host.
struct AccountSettingsView: View {
    @AppStorage(SettingsKeys.imapUsername) private var username = ""
    @State private var password = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("iCloud Mail Account") {
                TextField("Email Address", text: $username, prompt: Text("you@icloud.com"))
                    .textContentType(.username)
                SecureField("App-Specific Password", text: $password, prompt: Text("xxxx-xxxx-xxxx-xxxx"))
                Text("Generate an app-specific password at appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(isTesting ? "Testing…" : "Test & Save") {
                    testAndSave()
                }
                .disabled(isTesting || username.isEmpty || password.isEmpty)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear {
            if !username.isEmpty {
                password = KeychainStore.password(account: username) ?? ""
            }
        }
    }

    private func testAndSave() {
        isTesting = true
        statusIsError = false
        statusMessage = "Connecting to \(AppSettings.imapHost)…"
        let user = username
        let pass = password

        Task {
            do {
                let client = IMAPClient()
                try await client.connect(host: AppSettings.imapHost, username: user, password: pass)
                let inbox = try await client.selectInbox()
                await client.logout()
                try KeychainStore.savePassword(pass, account: user)
                statusMessage = "✓ Connected — INBOX has \(inbox.messageCount) message(s). Credentials saved."
                statusIsError = false
            } catch {
                statusMessage = "✗ \(error.localizedDescription)"
                statusIsError = true
            }
            isTesting = false
        }
    }
}
