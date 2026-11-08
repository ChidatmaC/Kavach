import Foundation

/// Decides when to ask "Was that a scam call?" after a phone call (CallKit `CXCallObserver`).
///
/// iOS only tells a running app about calls, and never the caller's number. The app keeps one
/// observer for its whole lifetime and feeds every change here; this value type decides, so it is
/// unit-tested without CallKit:
///
/// - Only **incoming** calls count (outgoing calls are the person's own).
/// - A call counts once it was seen ringing or connected and then ends.
/// - Each call is handled once (dedupe by CallKit UUID, persisted).
/// - While Call Companion is open it handles the end of the call itself (straight to the interview),
///   so nothing else is shown.
/// - Calls that ended while the app was suspended are found when the app becomes active again
///   (`reconcile`): the call we last saw is gone. Those get an in-app card on Home, not a notification,
///   if we last saw the call within `promptWindow`.
public struct CallFollowUpTracker: Codable, Sendable, Equatable {
    /// A CallKit call as the observer reports it.
    public struct Call: Sendable, Equatable {
        public var uuid: UUID
        public var isOutgoing: Bool
        public var hasConnected: Bool
        public var hasEnded: Bool
        public init(uuid: UUID, isOutgoing: Bool, hasConnected: Bool = false, hasEnded: Bool = false) {
            self.uuid = uuid; self.isOutgoing = isOutgoing; self.hasConnected = hasConnected; self.hasEnded = hasEnded
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Nothing to do.
        case none
        /// Call Companion is open and handles the end of the call (no prompt).
        case companionHandles
        /// Post the local notification now (the app is alive) and show the Home card.
        case notify
        /// The call ended while the app was suspended: show the Home card.
        case prompt
    }

    struct Seen: Codable, Sendable, Equatable {
        var incoming: Bool
        var connected: Bool
        var lastSeen: Date
    }

    /// Calls we saw ringing or connected that haven't ended yet.
    var live: [UUID: Seen] = [:]
    /// Calls already handled (notified, prompted, or left to Call Companion), with when.
    var handled: [UUID: Date] = [:]
    /// When the call we're asking about ended (drives the Home card). nil = nothing to ask.
    public private(set) var pendingPromptAt: Date?
    /// Whether that call was ever connected (false = missed or declined). Optional so trackers saved
    /// before this existed still decode; nil reads as answered.
    public private(set) var pendingConnected: Bool?

    /// The call we're asking about was never connected (missed or declined).
    public var pendingWasMissed: Bool { pendingConnected == false }

    public static let promptWindow: TimeInterval = 30 * 60

    public init() {}

    /// Whether Home should show "Was that a scam call?" now.
    public func showsPrompt(now: Date = Date()) -> Bool {
        guard let at = pendingPromptAt else { return false }
        return now.timeIntervalSince(at) <= Self.promptWindow
    }

    /// The person answered (Report it / It was fine), or a report was started.
    public mutating func clearPrompt() { pendingPromptAt = nil; pendingConnected = nil }

    /// A `callChanged` event from the observer while the app is alive.
    public mutating func observe(_ call: Call, companionOpen: Bool, now: Date = Date()) -> Decision {
        prune(now: now)
        if !call.hasEnded {
            var seen = live[call.uuid] ?? Seen(incoming: !call.isOutgoing, connected: false, lastSeen: now)
            seen.incoming = seen.incoming && !call.isOutgoing
            seen.connected = seen.connected || call.hasConnected
            seen.lastSeen = now
            live[call.uuid] = seen
            return .none
        }
        // Ended. Use what we saw before; a call first seen as ended was still ringing a moment ago.
        let seen = live.removeValue(forKey: call.uuid)
        let incoming = (seen?.incoming ?? true) && !call.isOutgoing
        let connected = (seen?.connected ?? false) || call.hasConnected
        return finish(call.uuid, incoming: incoming, connected: connected, companionOpen: companionOpen,
                      endedAt: now, notify: true)
    }

    /// The app became active: calls we were tracking that are no longer live ended while suspended.
    /// `current` is `CXCallObserver.calls` right now.
    public mutating func reconcile(current: [Call], companionOpen: Bool, now: Date = Date()) -> Decision {
        prune(now: now)
        let stillLive = Set(current.filter { !$0.hasEnded }.map(\.uuid))
        var decision = Decision.none
        for (uuid, seen) in live where !stillLive.contains(uuid) {
            live.removeValue(forKey: uuid)
            guard now.timeIntervalSince(seen.lastSeen) <= Self.promptWindow else {
                handled[uuid] = now
                continue
            }
            let d = finish(uuid, incoming: seen.incoming, connected: seen.connected, companionOpen: companionOpen,
                           endedAt: now, notify: false)
            if d != .none { decision = d }
        }
        // Calls still going on: refresh "last seen" so a long call isn't mistaken for an old one.
        for uuid in stillLive where live[uuid] != nil { live[uuid]?.lastSeen = now }
        return decision
    }

    /// Before the app is suspended: remember when we last saw each live call.
    public mutating func touchLive(now: Date = Date()) {
        for k in live.keys { live[k]?.lastSeen = now }
    }

    private mutating func finish(_ uuid: UUID, incoming: Bool, connected: Bool, companionOpen: Bool, endedAt: Date,
                                 notify: Bool) -> Decision {
        guard incoming, handled[uuid] == nil else { return .none }
        handled[uuid] = endedAt
        if companionOpen { return .companionHandles }
        pendingPromptAt = endedAt
        pendingConnected = connected
        return notify ? .notify : .prompt
    }

    /// Forget handled calls after a day, and live calls we lost track of for over 12 hours.
    private mutating func prune(now: Date) {
        handled = handled.filter { now.timeIntervalSince($0.value) < 86_400 }
        live = live.filter { now.timeIntervalSince($0.value.lastSeen) < 12 * 3600 }
        if let at = pendingPromptAt, now.timeIntervalSince(at) > Self.promptWindow { clearPrompt() }
    }

    // MARK: Persistence (app-only UserDefaults)

    public static func load(from defaults: UserDefaults = .standard, key: String = "call_follow_up") -> CallFollowUpTracker {
        guard let data = defaults.data(forKey: key),
              let t = try? JSONDecoder().decode(CallFollowUpTracker.self, from: data) else { return CallFollowUpTracker() }
        return t
    }

    public func save(to defaults: UserDefaults = .standard, key: String = "call_follow_up") {
        defaults.set(try? JSONEncoder().encode(self), forKey: key)
    }
}

/// Copy for the follow-up notification and the Home card (one place, so they always match).
public enum CallFollowUpCopy {
    public static let category = "CALL_FOLLOWUP"
    public static let reportAction = "CALL_FOLLOWUP_REPORT"
    public static let fineAction = "CALL_FOLLOWUP_FINE"
    public static let title = "Was that a scam call?"
    public static let body = "Report it in 2 minutes to protect you and your family."
    /// A call that was never connected (missed or declined).
    public static let missedTitle = "Missed a call from an unknown number?"
    public static let missedBody = "If it looked like a scam, report it so others are warned."

    public static func title(missed: Bool) -> String { missed ? missedTitle : title }
    public static func body(missed: Bool) -> String { missed ? missedBody : body }
    public static let reportLabel = "Report it"
    public static let fineLabel = "It was fine"
}
