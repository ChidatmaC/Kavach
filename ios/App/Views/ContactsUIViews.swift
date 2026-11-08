import Contacts
import ContactsUI
import KavachKit
import SwiftUI

/// Presents Apple's contact picker (no Contacts permission needed: the person chooses one card and
/// only that card comes back). Attach with `.contactPicker(isPresented:onPick:)`.
private struct ContactPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (CNContact) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, host.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        DispatchQueue.main.async { host.present(picker, animated: true) }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPickerPresenter
        init(_ parent: ContactPickerPresenter) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            parent.isPresented = false
            parent.onPick(contact)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }
    }
}

extension View {
    func contactPicker(isPresented: Binding<Bool>, onPick: @escaping (CNContact) -> Void) -> some View {
        background(ContactPickerPresenter(isPresented: isPresented, onPick: onPick).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

/// A Contacts card: an existing contact ("Open in Contacts", needs access) or an unknown one built
/// from a family member's number (offers "Create New Contact" / "Add to Existing Contact").
struct ContactCardView: UIViewControllerRepresentable {
    enum Mode { case existing(CNContact), unknown(name: String, phone: String) }
    let mode: Mode
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc: CNContactViewController
        switch mode {
        case .existing(let c):
            vc = CNContactViewController(for: c)
            vc.allowsEditing = true
        case .unknown(let name, let phone):
            let c = CNMutableContact()
            let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
            c.givenName = parts.first ?? name
            if parts.count > 1 { c.familyName = parts[1] }
            c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
            vc = CNContactViewController(forUnknownContact: c)
            vc.contactStore = CNContactStore()
            vc.allowsActions = true
        }
        vc.delegate = context.coordinator
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in
            context.coordinator.onClose()
        })
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            onClose()
        }
    }
}

/// Selectable chip (≥44 pt tall, selected state shown with a checkmark, not color alone).
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true) }
                Text(title).font(TypeScale.callout.weight(.semibold))
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: Theme.minTarget)
            .background(selected ? Theme.accentSoft : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Theme.accent : Theme.separator, lineWidth: selected ? 2 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    /// DEBUG screenshots: `KAVACH_DEBUG_SCROLL=bottom|center` starts scroll views there.
    @ViewBuilder func debugScrollAnchor() -> some View {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["KAVACH_DEBUG_SCROLL"] {
        case "bottom": defaultScrollAnchor(.bottom).defaultScrollAnchor(.bottom, for: .sizeChanges)
        case "center": defaultScrollAnchor(.center).defaultScrollAnchor(.center, for: .sizeChanges)
        default: self
        }
        #else
        self
        #endif
    }
}
