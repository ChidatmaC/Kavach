import Contacts
import ContactsUI
import Foundation
import KavachKit
import Observation

/// Optional Contacts integration (asked only when the person opts in). With access it shows family
/// members' Contacts photos, keeps their names in step with Contacts, opens their card, and
/// suggests likely family members. Nothing from the address book is uploaded: only contacts the
/// person adds go to the backend, through `upsert_contact`.
@MainActor
@Observable
final class ContactsBridge {
    private let store: SharedStore
    private let cn = CNContactStore()

    /// The person turned the integration on in Settings or Family.
    private(set) var enabled: Bool
    private(set) var status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    /// Family contact id → thumbnail.
    private(set) var photos: [UInt64: Data] = [:]
    /// Family contact id → Contacts identifier (from the picker or matched by number).
    private(set) var links: [UInt64: ContactLink]
    private(set) var suggestions: [FamilyContactMapper.Suggestion] = []

    private var lastSync: Date = .distantPast

    init(store: SharedStore) {
        self.store = store
        enabled = store.bool(.contactsIntegration)
        links = store.contactLinks()
    }

    var hasAccess: Bool { status == .authorized || status == .limited }
    var isActive: Bool { enabled && hasAccess }

    /// Asks for access (system prompt) only now, when the person chose to turn it on.
    func enable() async -> Bool {
        enabled = true
        store.set(true, .contactsIntegration)
        if status == .notDetermined {
            _ = try? await cn.requestAccess(for: .contacts)
        }
        status = CNContactStore.authorizationStatus(for: .contacts)
        lastSync = .distantPast
        return hasAccess
    }

    func disable() {
        enabled = false
        store.set(false, .contactsIntegration)
        photos = [:]
        suggestions = []
    }

    func refreshStatus() { status = CNContactStore.authorizationStatus(for: .contacts) }

    /// Remember which card a family member came from (picker), with the name we saved as baseline.
    func link(contactId: UInt64, identifier: String, name: String) {
        links[contactId] = ContactLink(identifier: identifier, baselineName: name)
        store.saveContactLinks(links)
    }

    func linkedIdentifier(for contactId: UInt64) -> String? { links[contactId]?.identifier }

    // MARK: Sync (photos, names, suggestions)

    nonisolated private static var keys: [CNKeyDescriptor] { [
        CNContactIdentifierKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor, CNContactRelationsKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    ] }

    struct SyncResult: Sendable {
        var photos: [UInt64: Data] = [:]
        var links: [UInt64: ContactLink] = [:]
        var updates: [(Contact, String)] = []
        var suggestions: [FamilyContactMapper.Suggestion] = []
    }

    /// Reads the address book off the main thread; only results computed from it come back (and
    /// none of it leaves the phone).
    nonisolated private static func compute(family: [Contact], links old: [UInt64: ContactLink]) async -> SyncResult {
        await Task.detached(priority: .utility) { () -> SyncResult in
            var all: [CNContact] = []
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: req) { c, _ in all.append(c) }
            var r = SyncResult()
            for member in family {
                let match = old[member.id].flatMap { l in all.first { $0.identifier == l.identifier } }
                    ?? all.first { FamilyContactMapper.phones($0).contains { $0.e164 == member.phoneE164 } }
                guard let match else { continue }
                if let data = match.thumbnailImageData { r.photos[member.id] = data }
                let decision = ContactNameSync.decide(savedName: member.name, contactsName: FamilyContactMapper.displayName(match),
                                                      baseline: old[member.id]?.baselineName)
                r.links[member.id] = ContactLink(identifier: match.identifier, baselineName: decision.baseline)
                if let name = decision.update { r.updates.append((member, name)) }
            }
            r.suggestions = FamilyContactMapper.suggestions(from: all, excludingPhones: Set(family.map(\.phoneE164)))
            return r
        }.value
    }

    /// Refreshes photos and suggestions and returns name updates to save. Throttled to once a minute
    /// unless `force`.
    func sync(family: [Contact], force: Bool = false) async -> [(Contact, String)] {
        refreshStatus()
        guard isActive, force || Date().timeIntervalSince(lastSync) > 60 else { return [] }
        lastSync = Date()
        let r = await Self.compute(family: family, links: links)
        // Keep links made in the picker for members not matched this time (e.g. card deleted).
        var merged = links.filter { id, _ in family.contains { $0.id == id } }
        for (k, v) in r.links { merged[k] = v }
        links = merged
        store.saveContactLinks(links)
        if photos != r.photos { photos = r.photos }
        suggestions = r.suggestions
        return r.updates
    }

    /// A full card for `CNContactViewController` (needs access).
    func cardForViewing(contactId: UInt64, phone: String) -> CNContact? {
        guard hasAccess else { return nil }
        let keys = [CNContactViewController.descriptorForRequiredKeys()]
        if let id = links[contactId]?.identifier, let c = try? cn.unifiedContact(withIdentifier: id, keysToFetch: keys) {
            return c
        }
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone))
        return (try? cn.unifiedContacts(matching: predicate, keysToFetch: keys))?.first
    }

    #if DEBUG
    /// Screenshot helper: a draft from the first contact with a phone number.
    func firstDraft() -> FamilyDraft? {
        guard hasAccess else { return nil }
        var found: FamilyDraft?
        let req = CNContactFetchRequest(keysToFetch: Self.keys)
        try? cn.enumerateContacts(with: req) { c, stop in
            if let d = FamilyContactMapper.draft(from: c) { found = d; stop.pointee = true }
        }
        return found
    }
    #endif
}
