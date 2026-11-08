import CallKit
import Foundation

/// Observes call state while Call Companion is open. Fires `onCallEnded` once when a call that was
/// active (or connected) while observing ends. The Companion also shows an "I've hung up" button
/// because this event is not guaranteed (spec 11 "End of call", verify early item).
final class CallWatcher: NSObject, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    private var activeCalls: Set<UUID> = []
    var onCallEnded: (() -> Void)?

    var hasActiveCall: Bool { observer.calls.contains { !$0.hasEnded } }

    func start() {
        activeCalls = Set(observer.calls.filter { !$0.hasEnded }.map(\.uuid))
        observer.setDelegate(self, queue: .main)
    }

    func stop() {
        observer.setDelegate(nil, queue: nil)
        onCallEnded = nil
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let uuid = call.uuid
        let ended = call.hasEnded
        MainActor.assumeIsolated {
            if ended {
                if activeCalls.remove(uuid) != nil { onCallEnded?() }
            } else {
                activeCalls.insert(uuid)
            }
        }
    }
}
