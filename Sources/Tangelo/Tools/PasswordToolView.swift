import SwiftUI
import TangeloCore

struct PasswordToolView: View {
    enum Mode { case protect, unlock }
    let item: InputItem
    let mode: Mode
    let close: () -> Void

    @State private var password = ""
    @State private var confirm = ""
    @FocusState private var focused: Bool

    private var valid: Bool {
        mode == .unlock ? !password.isEmpty : (password.count >= 1 && password == confirm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: mode == .protect ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 26)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .protect ? "Add a password" : "Remove the password").font(.system(size: 14, weight: .semibold))
                    Text(mode == .protect ? "A protected copy of \(item.url.lastPathComponent) is saved next to it."
                                          : "An unlocked copy of \(item.url.lastPathComponent) is saved next to it.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).focused($focused)
            if mode == .protect {
                SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder)
                if !confirm.isEmpty && confirm != password {
                    Text("Passwords don't match.").font(.system(size: 11.5)).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                SecondaryButton(title: "Cancel", action: close)
                PrimaryButton(title: mode == .protect ? "Protect" : "Unlock", enabled: valid) { save() }
            }
        }
        .padding(22)
        .padding(.top, 12)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func save() {
        let item = self.item, pw = password, mode = self.mode
        let anchor = ToolPresenter.hudAnchor()
        close()
        JobRunner.shared.run(title: mode == .protect ? "Protecting PDF" : "Unlocking PDF", near: anchor) { ctx in
            if mode == .protect { try await PDFActions.protect(item, password: pw, ctx: ctx) }
            else { try await PDFActions.unlock(item, password: pw, ctx: ctx) }
        }
    }
}
