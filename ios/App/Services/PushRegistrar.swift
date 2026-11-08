import KavachKit
import LocalAuthentication
import UIKit
import UserNotifications

/// APNs registration and the TRUSTED_SENDER category (Yes requires Face ID before
/// `resolve_verification`).
final class PushRegistrar: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistrar()
    static let trustedSenderCategory = "TRUSTED_SENDER"
    static let yesAction = "TRUSTED_SENDER_YES"
    static let noAction = "TRUSTED_SENDER_NO"

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let yes = UNNotificationAction(identifier: Self.yesAction, title: "Yes, I sent it",
                                       options: [.authenticationRequired, .foreground])
        let no = UNNotificationAction(identifier: Self.noAction, title: "No, it wasn't me", options: [.destructive])
        // After an incoming call ends (local notification from CallFollowUpCenter).
        let report = UNNotificationAction(identifier: CallFollowUpCopy.reportAction, title: CallFollowUpCopy.reportLabel,
                                          options: [.foreground])
        let fine = UNNotificationAction(identifier: CallFollowUpCopy.fineAction, title: CallFollowUpCopy.fineLabel, options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.trustedSenderCategory, actions: [yes, no], intentIdentifiers: []),
            UNNotificationCategory(identifier: CallFollowUpCopy.category, actions: [report, fine], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KAVACH_DEBUG_NO_PUSH_PROMPT"] == "1" { return }
        #endif
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
            await AppModel.shared.refreshNotificationStatus()
        }
    }

    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let vid = Self.verificationId(from: info)
        if category == CallFollowUpCopy.category {
            await MainActor.run {
                // Tapping the banner or "Report it" opens Report a call; "It was fine" just clears it.
                if action == CallFollowUpCopy.fineAction || action == UNNotificationDismissActionIdentifier {
                    CallFollowUpCenter.shared.dismiss()
                } else {
                    CallFollowUpCenter.shared.report()
                }
            }
            return
        }
        await MainActor.run {
            guard let vid else { return }
            switch action {
            case Self.yesAction: Task { await Self.answerTrustedSender(verificationId: vid, confirmed: true) }
            case Self.noAction: Task { await Self.answerTrustedSender(verificationId: vid, confirmed: false) }
            default: break // tapping the banner opens the app; Home shows the pending check
            }
        }
    }

    nonisolated static func verificationId(from info: [AnyHashable: Any]) -> UInt64? {
        if let n = info["verification_id"] as? NSNumber { return n.uint64Value }
        if let s = info["verification_id"] as? String { return UInt64(s) }
        return nil
    }

    /// "Yes" needs the device owner (Face ID / passcode) first; "No" does not.
    static func answerTrustedSender(verificationId: UInt64, confirmed: Bool) async {
        if confirmed {
            guard await authenticate(reason: "Confirm it was you who sent this message.") else { return }
        }
        _ = await AppModel.shared.run { try await $0.resolveVerification(id: verificationId, confirmed: confirmed) }
    }

    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushRegistrar.shared.configure()
        CallFollowUpCenter.shared.start()
        // After onboarding's Save-to-Contacts step, so the two prompts don't stack.
        if AppModel.shared.isRegistered && !AppModel.shared.shouldOfferAgentContact {
            PushRegistrar.shared.requestAuthorization()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = PushRegistrar.hex(deviceToken)
        Task { await AppModel.shared.saveAPNsToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no aps entitlement: the in-app pending-check card still works.
    }
}
