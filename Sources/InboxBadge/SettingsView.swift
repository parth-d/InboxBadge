import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Accounts") {
                if model.accounts.isEmpty { Text("No accounts yet.").foregroundStyle(.secondary) }
                ForEach(model.accounts) { account in
                    HStack {
                        Text(account.email)
                        Spacer()
                        Button("Remove", role: .destructive) { Task { await model.removeAccount(account.email) } }
                    }
                }
                HStack {
                    Button(model.hasClient ? "Add account (same Google client)…" : "Add account…") {
                        if model.hasClient { model.startSignIn(clientJSON: nil) } else { model.showImporter = true }
                    }
                    .disabled(model.isSigningIn)
                    if model.hasClient {
                        Button("Add with another client JSON…") { model.showImporter = true }.disabled(model.isSigningIn)
                    }
                }
                if model.isSigningIn {
                    HStack {
                        Text("Waiting for Google in your browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelSignIn() }
                    }
                }
                if let error = model.signInError { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
        .fileImporter(isPresented: Binding(get: { model.showImporter }, set: { model.showImporter = $0 }), allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            model.startSignIn(clientJSON: data)
        }
    }
}
