import Contacts
import KavachKit
import SwiftUI
import UIKit

/// Family: members (with Contacts photos when allowed), add from Contacts or by number, Contacts
/// integration, pause alerts, code word, recent family replies, Verify a relative.
struct FamilyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var picking = false
    @State private var form: FormSheet?
    @State private var card: CardSheet?
    @State private var codeWord = ""
    @State private var editingCodeWord = false
    @State private var pickProblem: String?

    struct FormSheet: Identifiable {
        let id = UUID()
        var draft: FamilyDraft
        var editing: Contact?
        var fromContacts: Bool
    }

    struct CardSheet: Identifiable {
        let id = UUID()
        let mode: ContactCardView.Mode
    }

    private var bridge: ContactsBridge { model.contactsBridge }

    var body: some View {
        List {
            membersSection
            if bridge.isActive && !bridge.suggestions.isEmpty { suggestionsSection }
            contactsSection
            alertsSection
            codeWordSection
            repliesSection
            Section {
                NavigationLink { VerifyRelativeView() } label: {
                    rowLabel("Verify a relative", detail: "Someone says they're family? We'll ask that person on their own number.",
                             icon: "person.badge.shield.checkmark")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .debugScrollAnchor()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .kavachScreenBackground()
        .navigationTitle("Family")
        .refreshable { await model.refresh(); await model.syncContacts(force: true) }
        .task { await model.syncContacts(force: true) }
        .contactPicker(isPresented: $picking) { picked in
            guard let d = FamilyContactMapper.draft(from: picked) else {
                pickProblem = "That contact has no phone number we can text. Pick another, or type a number instead."
                return
            }
            Task {
                try? await Task.sleep(for: .milliseconds(450)) // let the picker finish dismissing
                form = FormSheet(draft: d, editing: nil, fromContacts: true)
            }
        }
        .sheet(item: $form) { f in
            NavigationStack { FamilyMemberForm(draft: f.draft, editing: f.editing, fromContacts: f.fromContacts) }
                .kavachDisplay(model.prefs).environment(model)
        }
        .sheet(item: $card) { c in
            ContactCardView(mode: c.mode) { card = nil }.ignoresSafeArea()
        }
        .alert("Can't use that contact", isPresented: Binding(get: { pickProblem != nil }, set: { if !$0 { pickProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(pickProblem ?? "") }
        .onAppear {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["KAVACH_DEBUG_FAMILY"] {
            case "picker": picking = true
            case "form":
                let d = bridge.firstDraft() ?? FamilyDraft(name: "Tommy Rivera", phones: [
                    .init(label: "iPhone", e164: "+15125550142"), .init(label: "work", e164: "+15125550188"),
                ], phoneE164: "+15125550142", relationship: "Grandson")
                form = FormSheet(draft: d, editing: nil, fromContacts: true)
            case "manual": form = FormSheet(draft: FamilyDraft(), editing: nil, fromContacts: false)
            default: break
            }
            #endif
        }
    }

    // MARK: Sections

    private var membersSection: some View {
        Section {
            ForEach(model.contacts) { c in
                Button { form = FormSheet(draft: draft(for: c), editing: c, fromContacts: false) } label: {
                    FamilyMemberRow(contact: c, photo: bridge.photos[c.id],
                                    status: FamilyReplies.memberStatus(c, in: model.alertRequests))
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Remove", role: .destructive) { remove(c) }
                }
                .contextMenu {
                    if let url = URL(string: "tel:\(c.phoneE164)") {
                        Button { openURL(url) } label: { Label("Call", systemImage: "phone") }
                    }
                    contactCardButton(for: c)
                    Button(role: .destructive) { remove(c) } label: { Label("Remove", systemImage: "trash") }
                }
                .accessibilityHint("Double tap to edit. Swipe up or down for more actions.")
                .accessibilityAction(named: "Remove") { remove(c) }
                .accessibilityAction(named: bridge.hasAccess ? "Open in Contacts" : "Add to Contacts") { openCard(c) }
            }
            Button { picking = true } label: {
                rowLabel("Add from Contacts", detail: "Pick someone you already have saved.", icon: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("family.addFromContacts")
            Button { form = FormSheet(draft: FamilyDraft(), editing: nil, fromContacts: false) } label: {
                Text("Type a name and number instead").font(TypeScale.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent).frame(minHeight: Theme.minTarget)
            }
            .accessibilityIdentifier("family.addManually")
        } header: {
            Text("Your family")
        } footer: {
            Text("People get alerts only after they accept your invite by text. You can pause or remove anyone at any time.")
        }
        .listRowBackground(Theme.surface)
    }

    private var suggestionsSection: some View {
        Section {
            ForEach(bridge.suggestions) { s in
                HStack(spacing: Theme.Space.s) {
                    MonogramAvatar(name: s.name, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                        Text(s.relationship).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Add") { form = FormSheet(draft: s.draft, editing: nil, fromContacts: true) }
                        .buttonStyle(KavachButtonStyle(.secondary))
                        .fixedSize()
                        .accessibilityLabel("Add \(s.name)")
                }
                .frame(minHeight: Theme.minTarget)
            }
        } header: {
            Text("Suggested from your Contacts")
        } footer: {
            Text("Based on relationships in your Contacts. Nothing is shared until you add someone.")
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder private var contactsSection: some View {
        Section {
            if bridge.isActive {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "person.crop.circle.badge.checkmark").font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.safe).frame(width: Theme.Icon.s).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Using Contacts").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                        Text("Photos and names stay in step with your Contacts.").font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Turn off") { bridge.disable() }.font(TypeScale.callout.weight(.semibold))
                        .frame(minHeight: Theme.minTarget)
                }
            } else if bridge.enabled && (bridge.status == .denied || bridge.status == .restricted) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Contacts access is off").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text("To show photos and keep names up to date, allow Contacts for \(model.config.displayName) in Settings.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .frame(minHeight: Theme.minTarget)
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Show photos from Contacts").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                    Text("\(model.config.displayName) can show your family's photos, keep their names up to date and suggest family members. Your address book stays on this phone; only people you add are shared.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Button {
                        Task { if await bridge.enable() { await model.syncContacts(force: true) } }
                    } label: { Label("Use Contacts", systemImage: "person.crop.circle") }
                        .buttonStyle(KavachButtonStyle(.secondary))
                }
                .padding(.vertical, Theme.Space.xxs)
            }
        } header: {
            Text("Contacts")
        }
        .listRowBackground(Theme.surface)
    }

    private var alertsSection: some View {
        Section {
            // Bound to the polled person row: flips at once, reverts on error, and follows
            // "pause"/"resume" texted to the agent.
            SettingToggleRow(.sharingPaused, title: "Pause family alerts",
                             detail: model.person?.sharingPaused == true
                                ? "Your family isn't told about new alerts until you resume."
                                : "Your family is told when something serious happens.",
                             isOn: model.binding(for: .sharingPaused))
            if let e = model.lastError {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.caution)
                    .accessibilityLabel("Problem: \(e)")
            }
        } header: {
            Text("Family alerts")
        } footer: {
            Text("You can also text “pause” or “resume” to \(model.config.displayName).")
        }
        .listRowBackground(Theme.surface)
    }

    private var codeWordSection: some View {
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
                    let word = model.person?.familyCodeWord ?? ""
                    Label(word.isEmpty ? "Not set" : "“\(word)”", systemImage: "key")
                        .foregroundStyle(word.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    Spacer()
                    Button(word.isEmpty ? "Set" : "Change") { codeWord = word; editingCodeWord = true }
                        .font(TypeScale.callout.weight(.semibold))
                }
                .frame(minHeight: Theme.minTarget)
            }
        } header: {
            Text("Family code word")
        } footer: {
            Text("A word only your family knows. If a caller claims to be family, ask for it.")
        }
        .listRowBackground(Theme.surface)
    }

    /// What the family was told and whether they answered (Family Safety Thread).
    private var repliesSection: some View {
        Section {
            let recent = Array(model.alertRequests.prefix(4))
            if recent.isEmpty {
                Text("Nothing shared yet. When something serious happens, your family hears about it by text, and you'll see here when they reply.")
                    .font(TypeScale.body).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(recent) { r in
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Label(FamilyReplies.headline(r, contacts: model.contacts),
                              systemImage: r.phase == .acknowledged ? "checkmark.circle.fill" : (r.isUrgent ? "exclamationmark.triangle.fill" : "clock"))
                            .font(TypeScale.headline)
                            .foregroundStyle(r.phase == .acknowledged ? Theme.safe : (r.isUrgent ? Theme.caution : Theme.textPrimary))
                        Text(FamilyReplies.detail(r)).font(TypeScale.callout).foregroundStyle(Theme.textSecondary)
                        if let d = r.createdAt.date {
                            Text(d, format: .relative(presentation: .named)).font(TypeScale.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.vertical, Theme.Space.xxs)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Recent family replies")
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: Helpers

    private func rowLabel(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            IconTile(icon, tone: .info)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(minHeight: Theme.minTarget)
    }

    @ViewBuilder private func contactCardButton(for c: Contact) -> some View {
        Button { openCard(c) } label: {
            Label(bridge.hasAccess ? "Open in Contacts" : "Add to Contacts", systemImage: "person.crop.rectangle")
        }
    }

    private func openCard(_ c: Contact) {
        if let existing = bridge.cardForViewing(contactId: c.id, phone: c.phoneE164) {
            card = CardSheet(mode: .existing(existing))
        } else {
            card = CardSheet(mode: .unknown(name: c.name, phone: c.phoneE164))
        }
    }

    private func remove(_ c: Contact) {
        Task { _ = await model.run { try await $0.removeContact(c.id) } }
    }

    private func draft(for c: Contact) -> FamilyDraft {
        FamilyDraft(name: c.name, phones: [], phoneE164: c.phoneE164, relationship: c.relationship,
                    channel: c.channelKind ?? .sms, isEmergencyContact: c.isEmergencyContact,
                    contactIdentifier: bridge.linkedIdentifier(for: c.id))
    }
}

/// A family member row: photo or initials, name, relationship · channel, consent and reply status.
struct FamilyMemberRow: View {
    let contact: Contact
    let photo: Data?
    let status: FamilyReplies.MemberStatus

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            MonogramAvatar(name: contact.name, size: Theme.Icon.l, imageData: photo)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                Text([contact.relationship, contact.channelKind?.label ?? contact.channel,
                      contact.isEmergencyContact ? "Emergency contact" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                ConsentLabel(status: contact.consentStatus)
            }
            Spacer(minLength: Theme.Space.xs)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Space.xxs)
        .frame(minHeight: Theme.minTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([contact.name, contact.relationship, contact.channelKind?.label ?? contact.channel,
                             ConsentLabel.label(contact.consentStatus),
                             contact.isEmergencyContact ? "emergency contact" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

struct ConsentLabel: View {
    let status: String
    static func label(_ s: String) -> String {
        switch s {
        case "accepted": "Gets alerts"
        case "declined": "Declined"
        default: "Invite sent"
        }
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status == "accepted" ? "checkmark.circle.fill" : status == "declined" ? "xmark.circle" : "paperplane")
                .accessibilityHidden(true)
            Text(Self.label(status))
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(status == "accepted" ? Theme.safe : Theme.textSecondary)
    }
}

/// Add or edit a family member. From Contacts: name and numbers come from the card (pick one if
/// several). Relationship from quick chips, channel defaults to iMessage, emergency toggle.
struct FamilyMemberForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: FamilyDraft
    let editing: Contact?
    let fromContacts: Bool
    @State private var busy = false
    @State private var otherRelationship = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Space.s) {
                    MonogramAvatar(name: draft.name.isEmpty ? "?" : draft.name, size: 56,
                                   imageData: editing.flatMap { model.contactsBridge.photos[$0.id] })
                    TextField("Name", text: $draft.name)
                        .font(.title3.weight(.semibold))
                        .textContentType(.name)
                        .focused($nameFocused)
                        .frame(minHeight: Theme.minTarget)
                        .accessibilityLabel("Name")
                }
            } footer: {
                if fromContacts { Text("From your Contacts. You can change how the name appears here.") }
            }

            Section("Mobile number") {
                if draft.phones.count > 1 {
                    ForEach(draft.phones) { p in
                        Button { draft.phoneE164 = p.e164 } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(PhoneNumbers.formatted(p.e164)).font(TypeScale.body.monospacedDigit())
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(p.label).font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: draft.phoneE164 == p.e164 ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(draft.phoneE164 == p.e164 ? Theme.accent : Theme.borderStrong)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: Theme.minTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(p.label), \(PhoneNumbers.formatted(p.e164))")
                        .accessibilityAddTraits(draft.phoneE164 == p.e164 ? .isSelected : [])
                    }
                } else {
                    TextField("(555) 555-0101", text: $draft.phoneE164)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(TypeScale.body.monospacedDigit())
                        .frame(minHeight: Theme.minTarget)
                        .accessibilityLabel("Mobile number")
                    if !draft.phoneE164.isEmpty && PhoneNumbers.e164(draft.phoneE164) == nil {
                        Label("Use a 10-digit US number, or start with + and the country code.",
                              systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(Theme.caution)
                    }
                }
            }

            Section("Relationship") {
                FlowLayout {
                    ForEach(FamilyContactMapper.relationshipChips, id: \.self) { r in
                        Chip(title: r, selected: draft.relationship == r && !otherRelationship) {
                            draft.relationship = r; otherRelationship = false
                        }
                    }
                    Chip(title: "Other", selected: otherRelationship || isCustomRelationship) {
                        otherRelationship = true
                        if FamilyContactMapper.relationshipChips.contains(draft.relationship) { draft.relationship = "" }
                    }
                }
                .padding(.vertical, Theme.Space.xxs)
                if otherRelationship || isCustomRelationship {
                    TextField("For example, niece", text: $draft.relationship).frame(minHeight: Theme.minTarget)
                }
            }

            Section {
                Picker("How to reach them", selection: $draft.channel) {
                    ForEach(ContactChannel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(minHeight: Theme.minTarget)
                Toggle(isOn: $draft.isEmergencyContact) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emergency contact").font(TypeScale.headline)
                        Text("Always told in an emergency, even when alerts are paused (if you allow that in Settings).")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(minHeight: Theme.minTarget)
            } footer: {
                if editing == nil {
                    Text("We'll text \(draft.trimmedName.isEmpty ? "them" : FamilyReplies.shortName(draft.trimmedName)) an invite. They get alerts only after they accept. Only this name and number are shared with \(model.config.displayName).")
                }
            }

            if let e = model.lastError {
                Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.caution) }
            }

            Section {
                Button { Task { await save() } } label: {
                    if busy { ProgressView().tint(Theme.onAccent) } else {
                        Text(editing == nil ? "Add \(draft.trimmedName.isEmpty ? "family member" : FamilyReplies.shortName(draft.trimmedName))" : "Save changes")
                    }
                }
                .buttonStyle(KavachButtonStyle(.primary))
                .disabled(busy || !draft.isValid)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .kavachScreenBackground()
        .navigationTitle(editing == nil ? "Add family member" : "Edit \(FamilyReplies.shortName(editing!.name))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(busy || !draft.isValid)
            }
        }
        .onAppear {
            model.lastError = nil
            if !fromContacts && editing == nil { nameFocused = true }
        }
    }

    private var isCustomRelationship: Bool {
        !draft.relationship.isEmpty && !FamilyContactMapper.relationshipChips.contains(draft.relationship)
    }

    private func save() async {
        busy = true
        defer { busy = false }
        if await model.saveFamilyMember(draft, editing: editing) != nil || model.lastError == nil { dismiss() }
    }
}
