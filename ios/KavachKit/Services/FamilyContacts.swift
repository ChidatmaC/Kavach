import Contacts
import Foundation

/// A family member being added (from Contacts or typed). Only what the person confirms is sent to
/// the backend with `upsert_contact`; the address book itself never leaves the phone.
public struct FamilyDraft: Sendable, Equatable {
    public struct Phone: Sendable, Equatable, Hashable, Identifiable {
        public let label: String
        public let e164: String
        public var id: String { e164 }
        public init(label: String, e164: String) { self.label = label; self.e164 = e164 }
    }

    public var name: String
    public var phones: [Phone]
    public var phoneE164: String
    public var relationship: String
    public var channel: ContactChannel
    public var isEmergencyContact: Bool
    /// `CNContact.identifier` when picked from Contacts (kept on the phone for photos and name sync).
    public var contactIdentifier: String?

    public init(name: String = "", phones: [Phone] = [], phoneE164: String = "", relationship: String = "",
                channel: ContactChannel = .imessage, isEmergencyContact: Bool = false, contactIdentifier: String? = nil) {
        self.name = name; self.phones = phones; self.phoneE164 = phoneE164; self.relationship = relationship
        self.channel = channel; self.isEmergencyContact = isEmergencyContact; self.contactIdentifier = contactIdentifier
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isValid: Bool { !trimmedName.isEmpty && PhoneNumbers.e164(phoneE164) != nil }
}

public enum FamilyContactMapper {
    /// Quick chips on the add screen.
    public static let relationshipChips = ["Son", "Daughter", "Grandson", "Granddaughter", "Spouse", "Sister",
                                           "Brother", "Friend", "Neighbor", "Caregiver"]

    /// Keyword → canonical relationship, most specific first.
    static let keywords: [(String, String)] = [
        ("granddaughter", "Granddaughter"), ("grandson", "Grandson"), ("grandchild", "Grandchild"),
        ("grandmother", "Grandmother"), ("grandma", "Grandmother"), ("grandfather", "Grandfather"), ("grandpa", "Grandfather"),
        ("daughter", "Daughter"), ("son", "Son"), ("child", "Child"),
        ("mother", "Mother"), ("mom", "Mother"), ("mum", "Mother"), ("father", "Father"), ("dad", "Father"),
        ("sister", "Sister"), ("brother", "Brother"), ("sibling", "Sibling"),
        ("wife", "Spouse"), ("husband", "Spouse"), ("spouse", "Spouse"), ("partner", "Partner"),
        ("niece", "Niece"), ("nephew", "Nephew"), ("aunt", "Aunt"), ("uncle", "Uncle"), ("cousin", "Cousin"),
        ("caregiver", "Caregiver"), ("carer", "Caregiver"), ("friend", "Friend"), ("neighbor", "Neighbor"), ("neighbour", "Neighbor"),
    ]
    static let nonFamily: Set<String> = ["Friend", "Neighbor", "Caregiver"]

    /// Relationship named by a free-text label or nickname ("son", "Tommy (grandson)", "_$!<Son>!$_").
    public static func relationship(fromLabel raw: String) -> String? {
        let words = raw.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        for (k, v) in keywords where words.contains(k) { return v }
        return nil
    }

    /// Relationship from a Contacts relation label (localized name, then the raw label).
    public static func relationship(fromContactLabel label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return relationship(fromLabel: CNLabeledValue<CNContactRelation>.localizedString(forLabel: label))
            ?? relationship(fromLabel: label)
    }

    public static func displayName(_ c: CNContact) -> String {
        if c.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]),
           let s = CNContactFormatter.string(from: c, style: .fullName), !s.isEmpty {
            return s
        }
        if c.isKeyAvailable(CNContactNicknameKey), !c.nickname.isEmpty { return c.nickname }
        if c.isKeyAvailable(CNContactGivenNameKey) || c.isKeyAvailable(CNContactFamilyNameKey) {
            let s = [c.isKeyAvailable(CNContactGivenNameKey) ? c.givenName : "",
                     c.isKeyAvailable(CNContactFamilyNameKey) ? c.familyName : ""].filter { !$0.isEmpty }.joined(separator: " ")
            if !s.isEmpty { return s }
        }
        if c.isKeyAvailable(CNContactOrganizationNameKey) { return c.organizationName }
        return ""
    }

    /// The contact's numbers in E.164, mobile/iPhone first, without duplicates or unusable numbers.
    public static func phones(_ c: CNContact) -> [FamilyDraft.Phone] {
        guard c.isKeyAvailable(CNContactPhoneNumbersKey) else { return [] }
        let mobileLabels: Set<String> = [CNLabelPhoneNumberiPhone, CNLabelPhoneNumberMobile]
        var seen = Set<String>()
        let all: [(Int, FamilyDraft.Phone)] = c.phoneNumbers.compactMap { lv in
            guard let e = PhoneNumbers.e164(lv.value.stringValue), seen.insert(e).inserted else { return nil }
            let label = lv.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? "phone"
            return (mobileLabels.contains(lv.label ?? "") ? 0 : 1, FamilyDraft.Phone(label: label, e164: e))
        }
        return all.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
    }

    /// Relationship guessed from the contact itself (nickname or name such as "Tommy (grandson)").
    public static func guessedRelationship(_ c: CNContact) -> String? {
        if c.isKeyAvailable(CNContactNicknameKey), let r = relationship(fromLabel: c.nickname) { return r }
        return relationship(fromLabel: displayName(c))
    }

    /// A draft from a contact picked in `CNContactPickerViewController`; nil when it has no usable number.
    /// Channel defaults to iMessage (editable).
    public static func draft(from c: CNContact, relationship: String? = nil) -> FamilyDraft? {
        let ph = phones(c)
        guard let first = ph.first else { return nil }
        return FamilyDraft(name: displayName(c), phones: ph, phoneE164: first.e164,
                           relationship: relationship ?? guessedRelationship(c) ?? "", channel: .imessage,
                           isEmergencyContact: false, contactIdentifier: c.identifier)
    }

    public struct Suggestion: Sendable, Equatable, Identifiable {
        public let contactIdentifier: String
        public let name: String
        public let relationship: String
        public let draft: FamilyDraft
        public var id: String { contactIdentifier }
    }

    /// Likely family members: people named in another card's relations ("son: Tommy Rivera", e.g. on
    /// the person's own card) and contacts whose name or nickname says it ("Grandson Sam"). Family
    /// relations rank above friends/neighbors. Contacts already added (by number) are left out.
    public static func suggestions(from contacts: [CNContact], excludingPhones: Set<String>, limit: Int = 5) -> [Suggestion] {
        var byIdentifier: [String: (rank: Int, relationship: String, contact: CNContact)] = [:]
        func consider(_ c: CNContact, _ rel: String) {
            let rank = nonFamily.contains(rel) ? 1 : 2
            if let existing = byIdentifier[c.identifier], existing.rank >= rank { return }
            byIdentifier[c.identifier] = (rank, rel, c)
        }
        let names: [(CNContact, String, String)] = contacts.map { c in
            let full = displayName(c).lowercased()
            let given = c.isKeyAvailable(CNContactGivenNameKey) ? c.givenName.lowercased() : ""
            return (c, full, given)
        }
        for c in contacts where c.isKeyAvailable(CNContactRelationsKey) {
            for rel in c.contactRelations {
                guard let r = relationship(fromContactLabel: rel.label) else { continue }
                let target = rel.value.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { continue }
                for (other, full, given) in names where other.identifier != c.identifier && (full == target || given == target) {
                    consider(other, r)
                }
            }
        }
        for c in contacts { if let r = guessedRelationship(c) { consider(c, r) } }

        return byIdentifier.values
            .compactMap { entry -> (Int, Suggestion)? in
                guard var d = draft(from: entry.contact, relationship: entry.relationship),
                      !d.phones.contains(where: { excludingPhones.contains($0.e164) }) else { return nil }
                d.relationship = entry.relationship
                return (entry.rank, Suggestion(contactIdentifier: entry.contact.identifier, name: d.name,
                                               relationship: entry.relationship, draft: d))
            }
            .sorted { ($0.0, $1.1.name) > ($1.0, $0.1.name) }
            .prefix(limit)
            .map(\.1)
    }
}

/// Keeps family names in step with Contacts. Each linked family member remembers the Contacts name
/// it last saw (the baseline). When the Contacts name changes away from the baseline and differs
/// from the saved name, the app updates the backend with `upsert_contact`. A name the person edited
/// in the app is never overwritten until it changes in Contacts again.
public enum ContactNameSync {
    public struct Decision: Sendable, Equatable {
        /// New name to save with `upsert_contact`, or nil when nothing to do.
        public let update: String?
        public let baseline: String
    }

    public static func decide(savedName: String, contactsName: String, baseline: String?) -> Decision {
        let cn = contactsName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cn.isEmpty else { return Decision(update: nil, baseline: baseline ?? savedName) }
        guard let baseline else { return Decision(update: nil, baseline: cn) } // first link: just remember it
        if cn == baseline { return Decision(update: nil, baseline: baseline) }
        return Decision(update: cn == savedName ? nil : cn, baseline: cn)
    }
}
