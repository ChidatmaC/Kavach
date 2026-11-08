import CallKit
import Foundation
import KavachKit
import UserNotifications

/// Watches phone calls for the whole app lifetime (not only inside Call Companion) and follows up
/// after an incoming call ends: a local notification "Was that a scam call?" while the app is alive,
/// and a card on Home (also for calls that ended while the app was suspended). The decisions are in
/// `CallFollowUpTracker` (KavachKit, unit-tested); this class only wires CallKit and notifications.
///
/// iOS never tells apps the caller's number, so the Report-a-call flow asks for it.
final class CallFollowUpCenter: NSObject, CXCallObserverDelegate {
    static let shared = CallFollowUpCenter()

    private let observer = CXCallObserver()
    private var tracker = CallFollowUpTracker.load()
    private var started = false

    /// Call Companion handles the end of its own call (straight to the interview).
    private var companionOpen: Bool { AppModel.shared.route == .companion }

    func start() {
        guard !started else { return }
        started = true
        observer.setDelegate(self, queue: .main)
        publish()
    }

    /// Scene became active: find calls that ended while we were suspended.
    func appBecameActive() {
        start()
        let current = observer.calls.map(Self.snapshot)
        _ = tracker.reconcile(current: current, companionOpen: companionOpen)
        persist()
        publish()
    }

    /// Scene going to the background: remember when we last saw each live call.
    func appEnteredBackground() {
        tracker.touchLive()
        persist()
    }

    /// "Report it" (notification action, banner tap or the Home card).
    func report() {
        tracker.clearPrompt()
        persist()
        publish()
        AppModel.shared.route = .reportCall
    }

    /// A report was started some other way: the question has been answered.
    func dismissPromptOnly() {
        guard tracker.showsPrompt() else { return }
        tracker.clearPrompt()
        persist()
        publish()
    }

    /// "It was fine".
    func dismiss() {
        tracker.clearPrompt()
        persist()
        publish()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications(withCategory: CallFollowUpCopy.category)
    }

    #if DEBUG
    func debugShowPrompt(missed: Bool = false) {
        _ = tracker.observe(.init(uuid: UUID(), isOutgoing: false, hasConnected: !missed, hasEnded: true), companionOpen: false)
        publish()
    }
    #endif

    // MARK: CXCallObserverDelegate

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let snap = Self.snapshot(call)
        MainActor.assumeIsolated {
            let decision = tracker.observe(snap, companionOpen: companionOpen)
            persist()
            switch decision {
            case .notify:
                postNotification()
                publish()
            case .prompt:
                publish()
            case .none, .companionHandles:
                break
            }
        }
    }

    // MARK: Private

    nonisolated private static func snapshot(_ c: CXCall) -> CallFollowUpTracker.Call {
        .init(uuid: c.uuid, isOutgoing: c.isOutgoing, hasConnected: c.hasConnected, hasEnded: c.hasEnded)
    }

    private func persist() { tracker.save() }

    private func publish() {
        let show = tracker.showsPrompt()
        if AppModel.shared.callFollowUpPending != show { AppModel.shared.callFollowUpPending = show }
        let missed = show && tracker.pendingWasMissed
        if AppModel.shared.callFollowUpMissed != missed { AppModel.shared.callFollowUpMissed = missed }
    }

    private func postNotification() {
        let content = UNMutableNotificationContent()
        content.title = CallFollowUpCopy.title(missed: tracker.pendingWasMissed)
        content.body = CallFollowUpCopy.body(missed: tracker.pendingWasMissed)
        content.sound = .default
        content.categoryIdentifier = CallFollowUpCopy.category
        content.interruptionLevel = .active
        content.userInfo = ["kind": "call_followup"]
        let request = UNNotificationRequest(identifier: "call-followup-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension UNUserNotificationCenter {
    func removeAllDeliveredNotifications(withCategory category: String) {
        getDeliveredNotifications { list in
            let ids = list.filter { $0.request.content.categoryIdentifier == category }.map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}
