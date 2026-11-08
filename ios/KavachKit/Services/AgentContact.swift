import Contacts
import Foundation
import UIKit

/// The agent's iMessage line as a contact card, so people never have to search for or type the number.
/// iOS can't add a contact silently, so onboarding presents Apple's prefilled new-contact card
/// (`CNContactViewController(forNewContact:)`, no Contacts permission needed) and the person taps Done.
public enum AgentContact {
    public static func note(displayName: String) -> String {
        "Text me any message you're unsure about and I'll tell you if it looks like a scam. — \(displayName)"
    }

    /// A new, unsaved contact: given name = the app's display name, the agent number labeled iPhone,
    /// a short note and (when available) an avatar image.
    public static func make(displayName: String, number: String, imageData: Data? = nil) -> CNMutableContact {
        let c = CNMutableContact()
        c.contactType = .person
        c.givenName = displayName
        c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberiPhone, value: CNPhoneNumber(stringValue: number))]
        c.note = note(displayName: displayName)
        if let imageData { c.imageData = imageData }
        return c
    }

    public static func make(config: AppConfig, imageData: Data? = nil) -> CNMutableContact {
        make(displayName: config.displayName, number: config.agentLineNumber, imageData: imageData)
    }

    /// `sms:` URL that opens Messages (iMessage when available) to the agent line.
    public static func messagesURL(number: String) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 8 else { return nil }
        return URL(string: "sms:\(digits)")
    }

    /// "+1 (415) 610-6180" for display and VoiceOver.
    public static func formatted(_ number: String) -> String {
        let d = number.filter(\.isNumber)
        guard d.count == 11, d.hasPrefix("1") else { return number }
        let a = Array(d)
        return "+1 (\(String(a[1...3]))) \(String(a[4...6]))-\(String(a[7...10]))"
    }

    /// Whether the number is already in the person's contacts. Only looks when Contacts access was
    /// already granted for some other reason: never asks for permission just for this.
    public static func existsWithoutPrompting(number: String) -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized || status == .limited else { return false }
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        let found = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        return !(found ?? []).isEmpty
    }

    /// Contact photo: the app icon when the bundle has one, otherwise the shield symbol on the accent color.
    @MainActor public static func avatarPNG(accent: UIColor) -> Data? {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last, let icon = UIImage(named: name) {
            return icon.pngData()
        }
        let size = CGSize(width: 512, height: 512)
        let symbol = UIImage(systemName: "shield.lefthalf.filled",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 280, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            accent.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let symbol {
                let s = symbol.size
                symbol.draw(in: CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
            }
        }.pngData()
    }
}

/// Remembers (App Group) whether the Save-to-Contacts step was handled, so it shows only once.
public enum AgentContactPrompt: String, Sendable {
    case saved, dismissed

    public static func load(from store: SharedStore) -> AgentContactPrompt? {
        store.string(.agentContactPrompt).flatMap(AgentContactPrompt.init(rawValue:))
    }

    public static func save(_ value: AgentContactPrompt?, to store: SharedStore) {
        store.set(value?.rawValue, .agentContactPrompt)
    }
}
