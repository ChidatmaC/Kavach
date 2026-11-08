import Contacts
import ContactsUI
import KavachKit
import SwiftUI

/// Apple's prefilled new-contact card for the agent line. The person reviews it and taps Done to save
/// (no Contacts permission needed for this route). `onFinish(true)` when saved, `false` on Cancel.
struct AgentContactCardSheet: UIViewControllerRepresentable {
    let contact: CNContact
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = CNContactViewController(forNewContact: contact)
        vc.delegate = context.coordinator
        vc.allowsActions = false
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            onFinish(contact != nil)
        }
    }
}

extension AppModel {
    func makeAgentContact() -> CNContact {
        AgentContact.make(config: config, imageData: AgentContact.avatarPNG(accent: UIColor(Theme.accent)))
    }
}

/// Presents the contact card and records the outcome. Shared by onboarding, Settings and Home.
private struct AgentContactCardModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    var onSaved: () -> Void = {}

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            AgentContactCardSheet(contact: model.makeAgentContact()) { saved in
                isPresented = false
                if saved {
                    model.markAgentContact(.saved)
                    onSaved()
                }
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    func agentContactCard(isPresented: Binding<Bool>, onSaved: @escaping () -> Void = {}) -> some View {
        modifier(AgentContactCardModifier(isPresented: isPresented, onSaved: onSaved))
    }
}

/// Last onboarding step (after `register_person`): save the agent's iMessage line as a contact.
/// Shown once; "Not now" or saving both remember the choice in the App Group.
struct AgentContactStepView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCard = false

    var body: some View {
        let name = model.config.displayName
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                IconTile("person.crop.circle.badge.plus", tone: .info, size: 64)
                    .padding(.top, Theme.Space.l)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Save \(name) to your contacts")
                        .font(TypeScale.display).foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Then you can text \(name) any message you're unsure about, without looking up the number.")
                        .font(.title3).foregroundStyle(Theme.textSecondary)
                }
                Card {
                    HStack(spacing: Theme.Space.s) {
                        IconTile("message", tone: .info, size: Theme.Icon.l)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                            Text(AgentContact.formatted(model.agentNumber)).font(.title3.monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(name), \(AgentContact.formatted(model.agentNumber))")
                }
                Text("On the next screen, check the details and tap Done.")
                    .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
                VStack(spacing: Theme.Space.s) {
                    Button {
                        showingCard = true
                    } label: {
                        Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(KavachButtonStyle(.primary))
                    .accessibilityHint("Opens a new contact card for \(name), ready to save")
                    .accessibilityIdentifier("agentContact.save")
                    Button("Not now") { model.markAgentContact(.dismissed) }
                        .buttonStyle(KavachButtonStyle(.quiet))
                        .accessibilityHint("You can add it later in Settings")
                        .accessibilityIdentifier("agentContact.notNow")
                }
            }
            .padding(Theme.Space.m)
        }
        .kavachScreenBackground()
        .agentContactCard(isPresented: $showingCard)
        .onAppear {
            #if DEBUG
            if model.debugShowContactCard { showingCard = true }
            #endif
        }
    }
}

/// Settings rows: "Add Kavach to Contacts" (always available) and "Text Kavach".
struct AgentContactRows: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingCard = false

    var body: some View {
        let name = model.config.displayName
        let saved = model.agentContactPrompt == .saved
        Button { showingCard = true } label: {
            row(icon: saved ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus",
                tint: saved ? Theme.safe : Theme.accent,
                title: "Add \(name) to Contacts", detail: saved ? "Saved" : AgentContact.formatted(model.agentNumber))
        }
        .accessibilityHint("Opens a new contact card, ready to save")
        .accessibilityIdentifier("settings.addAgentContact")
        .agentContactCard(isPresented: $showingCard)
        .disabled(model.agentNumber.isEmpty)

        Button {
            if let url = AgentContact.messagesURL(number: model.agentNumber) { openURL(url) }
        } label: {
            row(icon: "message", tint: Theme.accent, title: "Text \(name)", detail: "Opens Messages")
        }
        .accessibilityHint("Opens Messages to \(name) at \(AgentContact.formatted(model.agentNumber))")
        .accessibilityIdentifier("settings.textAgent")
        .disabled(model.agentNumber.isEmpty)
    }

    private func row(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(tint)
                .frame(width: Theme.Icon.s).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(minHeight: Theme.minTarget)
    }
}

/// Small Home card while the agent isn't saved as a contact yet (hidden in Accessibility Mode, which
/// keeps Home to the three actions).
struct AgentContactHomeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var showingCard = false

    var body: some View {
        let name = model.config.displayName
        Card {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                IconTile("message", tone: .info)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Text \(name) any message").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text("Unsure about a text? Forward it to \(name) on iMessage at \(AgentContact.formatted(model.agentNumber)).")
                        .font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.s) { buttons(name) }
                VStack(spacing: Theme.Space.s) { buttons(name) }
            }
        }
        .agentContactCard(isPresented: $showingCard)
    }

    @ViewBuilder private func buttons(_ name: String) -> some View {
        Button { showingCard = true } label: { Label("Add to Contacts", systemImage: "person.crop.circle.badge.plus") }
            .buttonStyle(KavachButtonStyle(.secondary))
        Button {
            if let url = AgentContact.messagesURL(number: model.agentNumber) { openURL(url) }
        } label: { Label("Text \(name)", systemImage: "message") }
            .buttonStyle(KavachButtonStyle(.secondary))
    }
}
