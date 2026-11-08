import IdentityLookup
import KavachKit

/// Stretch: sends texts from unknown senders whose number has a community scam label to Junk.
/// Minimal by design: it uses the cached `caller_labels` feed (the agent's community verdicts)
/// and otherwise leaves the decision to Messages. Network deferral would need an HTTPS
/// `ILMessageFilterExtensionNetworkURL` endpoint on the agent service, which isn't in the contracts yet.
final class MessageFilterHandler: ILMessageFilterExtension, ILMessageFilterQueryHandling {
    func handle(_ queryRequest: ILMessageFilterQueryRequest, context: ILMessageFilterExtensionContext,
                completion: @escaping (ILMessageFilterQueryResponse) -> Void) {
        let response = ILMessageFilterQueryResponse()
        response.action = Self.action(sender: queryRequest.sender, labels: Self.labels())
        completion(response)
    }

    static func labels() -> [CallerLabel] {
        SharedStore(appGroup: AppConfig.fromInfoPlist(Bundle.main.infoDictionary ?? [:]).appGroup).loadCallerLabels()
    }

    static func action(sender: String?, labels: [CallerLabel]) -> ILMessageFilterAction {
        guard let sender else { return .none }
        let digits = sender.filter(\.isNumber)
        guard digits.count >= 7 else { return .none }
        let hit = labels.contains { l in
            let d = l.value.filter(\.isNumber)
            return d == digits || d.hasSuffix(digits) || digits.hasSuffix(d)
        }
        return hit ? .junk : .none
    }
}
