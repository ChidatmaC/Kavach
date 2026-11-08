import KavachKit
import SwiftUI

/// Family: contacts with channel + consent status, Safety Thread preview, pause sharing, code word,
/// Verify a relative, practice scheduling (Stretch).
struct FamilyView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Contact?
    @State private var adding = false
    @State private var codeWord = ""
    @State private var editingCodeWord = false

    var body: some View {
        List {
            Section {
                ForEach(model.contacts) { c in
                    Button { editing = c } label: { ContactRow(contact: c) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                Task { _ = await model.run { try await $0.removeContact(c.id) } }
                            }
                        }
                        .accessibilityHint("Double tap to edit. Swipe up or down for more actions.")
                        .accessibilityAction(named: "Remove") {
                            Task { _ = await model.run { try await $0.removeContact(c.id) } }
                        }
                }
                Button { adding = true } label: { Label("Add a family member", systemImage: "person.badge.plus") }
                    .frame(minHeight: Theme.minTarget)
            } header: {
                Text("Your family")
            } footer: {
                Text("People get alerts only after they accept your invite by text. You can pause or remove anyone at any time.")
            }

            Section("Sharing") {
                Toggle(isOn: Binding(
                    get: { model.person?.sharingPaused ?? false },
                    set: { v in Task { _ = await model.run { try await $0.setSharingPaused(personId: model.personId, paused: v) } } }
                )) {
                    Label("Pause sharing with family", systemImage: "pause.circle")
                }
                .frame(minHeight: Theme.minTarget)
            }

            Section {
                if editingCodeWord {
                    TextField("For example, blue pancake", text: $codeWord)
                        .frame(minHeight: Theme.minTarget)
                        .accessibilityLabel("Family code word")
                    Button("Save code word") {
                        let w = codeWord
                        Task {
                            await model.updateSettings { $0.familyCodeWord = w }
                            editingCodeWord = false
                        }
                    }
                    .frame(minHeight: Theme.minTarget)
                } else {
                    HStack {
                        Label(model.person?.familyCodeWord.isEmpty == false ? "“\(model.person!.familyCodeWord)”" : "Not set",
                              systemImage: "key.fill")
                        Spacer()
                        Button("Change") { codeWord = model.person?.familyCodeWord ?? ""; editingCodeWord = true }
                    }
                    .frame(minHeight: Theme.minTarget)
                }
            } header: {
                Text("Family code word")
            } footer: {
                Text("A word only your family knows. If a caller claims to be family, ask for it.")
            }

            Section("Family Safety Thread") {
                SafetyThreadPreview()
            }

            Section {
                NavigationLink { VerifyRelativeView() } label: {
                    Label("Verify a relative", systemImage: "person.badge.shield.checkmark.fill")
                }
                .frame(minHeight: Theme.minTarget)
                NavigationLink { PracticeView() } label: {
                    Label("Practice scams", systemImage: "graduationcap.fill")
                }
                .frame(minHeight: Theme.minTarget)
            }
        }
        .navigationTitle("Family")
        .refreshable { await model.refresh() }
        .sheet(isPresented: $adding) {
            NavigationStack { ContactEditor(contact: nil) }.kavachDisplay(model.prefs).environment(model)
        }
        .sheet(item: $editing) { c in
            NavigationStack { ContactEditor(contact: c) }.kavachDisplay(model.prefs).environment(model)
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contact.isEmergencyContact ? "star.circle.fill" : "person.circle.fill")
                .font(.title).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.headline)
                Text([contact.relationship, contact.channelKind?.label ?? contact.channel]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            ConsentBadge(status: contact.consentStatus)
        }
        .frame(minHeight: Theme.minTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(contact.name), \(contact.relationship), \(contact.channelKind?.label ?? contact.channel), \(ConsentBadge.label(contact.consentStatus))\(contact.isEmergencyContact ? ", emergency contact" : "")")
    }
}

struct ConsentBadge: View {
    let status: String
    static func label(_ s: String) -> String {
        switch s {
        case "accepted": "Accepted"
        case "declined": "Declined"
        default: "Invited"
        }
    }
    var body: some View {
        Label(Self.label(status), systemImage: status == "accepted" ? "checkmark.circle.fill"
              : status == "declined" ? "xmark.circle" : "clock")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(status == "accepted" ? Theme.safe : .secondary)
    }
}

/// What the family has been told, built from the person's own incidents (the outbox is
/// service-only, D15). Display only.
struct SafetyThreadPreview: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let shared = model.incidents.filter { $0.entryPoint == "companion" || $0.severityLevel >= .high }.prefix(4)
        if shared.isEmpty {
            Text("Nothing shared yet. When something serious happens, your family hears about it here and by text.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(shared)) { inc in
                VStack(alignment: .leading, spacing: 4) {
                    Text(line(for: inc)).font(.body)
                    HStack {
                        if let d = inc.createdAt.date { Text(d, style: .relative).font(.footnote).foregroundStyle(.secondary) }
                        if inc.familyAckBy != 0, let c = model.contacts.first(where: { $0.id == inc.familyAckBy }) {
                            Text("· \(c.name) is on it").font(.footnote.weight(.semibold)).foregroundStyle(Theme.safe)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func line(for inc: Incident) -> String {
        switch inc.severityLevel {
        case .critical: "Urgent alert: you may have shared something important."
        case .high: "Alert: you may have shared some personal details."
        default: "You asked for help during a call."
        }
    }
}

struct ContactEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let contact: Contact?
    @State private var name = ""
    @State private var phone = ""
    @State private var relationship = ""
    @State private var channel: ContactChannel = .imessage
    @State private var emergency = false
    @State private var busy = false

    var body: some View {
        Form {
            TextField("Name", text: $name).frame(minHeight: Theme.minTarget)
            TextField("Mobile number", text: $phone).keyboardType(.phonePad).frame(minHeight: Theme.minTarget)
            TextField("Relationship (e.g. grandson)", text: $relationship).frame(minHeight: Theme.minTarget)
            Picker("How to reach them", selection: $channel) {
                ForEach(ContactChannel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .frame(minHeight: Theme.minTarget)
            Toggle("Emergency contact", isOn: $emergency).frame(minHeight: Theme.minTarget)
            if contact == nil {
                Text("We'll text them an invite. They get alerts only after they accept.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let e = model.lastError { Text(e).foregroundStyle(Theme.amber) }
        }
        .navigationTitle(contact == nil ? "Add family member" : "Edit \(contact!.name)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(busy || name.isEmpty || normalizePhone(phone).count < 8)
            }
        }
        .onAppear {
            guard let c = contact else { return }
            name = c.name; phone = c.phoneE164; relationship = c.relationship
            channel = c.channelKind ?? .sms; emergency = c.isEmergencyContact
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let ok = await model.run { api in
            try await api.upsertContact(personId: model.personId, contactId: contact?.id ?? 0, name: name,
                                        phone: normalizePhone(phone), relationship: relationship,
                                        channel: channel, isEmergency: emergency)
        }
        if ok { dismiss() }
    }
}

/// Verify a relative → `/app/verify`. The agent texts the relative's saved number and starts the deadline.
struct VerifyRelativeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var result: VerifyResult?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Who do they say they are? We'll ask that person on their own number.")
                    .font(.title3)
                ForEach(model.contacts) { c in
                    Button { Task { await verify(c.name) } } label: {
                        Label(c.name, systemImage: "person.fill")
                    }
                    .buttonStyle(KavachButtonStyle())
                }
                TextField("Someone else (name)", text: $name)
                    .textFieldStyle(.roundedBorder).frame(minHeight: Theme.minTarget)
                Button("Verify \(name.isEmpty ? "this person" : name)") { Task { await verify(name) } }
                    .buttonStyle(KavachButtonStyle(prominent: true))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                if busy { ProgressView("Asking them…") }
                if let result {
                    Card {
                        Label("We're checking", systemImage: "hourglass").font(.headline)
                        ForEach(result.messages, id: \.self) { Text($0) }
                        if result.messages.isEmpty {
                            Text("We've asked them. You'll get a text when they answer. Until then, don't send anything.")
                        }
                    }
                }
                if let error {
                    Card {
                        Label("Couldn't start the check", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.amber).font(.headline)
                        Text("Hang up, then call them yourself on the number you know. Don't send money or codes.")
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Verify a relative")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }

    private func verify(_ who: String) async {
        guard let api = model.api else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            result = try await api.verifyRelative(name: who)
            if model.prefs.autoSpeak { Speaker.shared.speak(result?.messages.joined(separator: " ") ?? "") }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Practice scams (Stretch): only with practice consent (module enforces it too).
struct PracticeView: View {
    @Environment(AppModel.self) private var model
    @State private var contactId: UInt64 = 0
    @State private var template = "unpaid_toll"
    @State private var when = Date().addingTimeInterval(3600)
    @State private var status: String?

    private let templates = [("unpaid_toll", "Unpaid toll text"), ("grandchild_emergency", "Grandchild emergency"),
                             ("carrier_fraud", "Phone company code request"), ("remote_job", "Job offer")]

    var body: some View {
        Form {
            if model.person?.practiceConsent != true {
                Text("Practice scams are off. Turn on practice consent in Settings first.")
            } else {
                Picker("From", selection: $contactId) {
                    ForEach(model.contacts) { Text($0.name).tag($0.id) }
                }
                Picker("Kind", selection: $template) {
                    ForEach(templates, id: \.0) { Text($0.1).tag($0.0) }
                }
                DatePicker("Send at", selection: $when, in: Date()...)
                Button("Schedule practice text") {
                    Task {
                        let ok = await model.run {
                            try await $0.scheduleDrill(personId: model.personId, contactId: contactId,
                                                       templateKey: template, sendAt: when)
                        }
                        status = ok ? "Scheduled. It's harmless and is revealed as practice right away if replied to."
                                    : model.lastError
                    }
                }
                .disabled(contactId == 0)
                .frame(minHeight: Theme.minTarget)
            }
            if let status { Text(status) }
            if !model.drills.isEmpty {
                Section("Past practice") {
                    ForEach(model.drills) { d in
                        HStack { Text(d.templateKey); Spacer(); Text(d.outcome.capitalized).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Practice scams")
        .onAppear { if contactId == 0 { contactId = model.contacts.first?.id ?? 0 } }
    }
}
