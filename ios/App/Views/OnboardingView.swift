import KavachKit
import SwiftUI

/// Phone + name → `register_person` (MVP: phone ownership is not SMS-verified).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var phone = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 64)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Welcome to \(model.config.displayName)")
                        .font(.largeTitle.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Check messages and calls, and let your family know when something feels wrong.")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your first name").font(.headline)
                        TextField("For example, Joe", text: $name)
                            .textContentType(.givenName)
                            .textFieldStyle(.roundedBorder).font(.title3)
                            .frame(minHeight: Theme.minTarget)
                            .accessibilityLabel("Your first name")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your mobile number").font(.headline)
                        TextField("(555) 555-0101", text: $phone)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .textFieldStyle(.roundedBorder).font(.title3)
                            .frame(minHeight: Theme.minTarget)
                            .accessibilityLabel("Your mobile number")
                    }
                    if let error {
                        Text(error).foregroundStyle(Theme.amber).accessibilityLabel("Problem: \(error)")
                    }
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy { ProgressView() } else { Text("Get started") }
                    }
                    .buttonStyle(KavachButtonStyle(prominent: true))
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || normalizePhone(phone).count < 8)

                    NavigationLink("Server settings") { ServerSettingsView() }
                        .frame(minHeight: Theme.minTarget)
                }
                .padding()
            }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do {
            try await model.register(phone: phone, name: name.trimmingCharacters(in: .whitespaces))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
