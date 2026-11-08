import CallKit
import Foundation
import KavachKit

/// Loads community caller labels (cached by the app in the App Group from the public
/// `caller_labels` view) as "Likely scam: N reports". The app calls reloadExtension when they change.
final class CallDirectoryHandler: CXCallDirectoryProvider {
    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        let store = SharedStore(appGroup: AppConfig.fromInfoPlist(Bundle.main.infoDictionary ?? [:]).appGroup)
        // CallKit requires strictly ascending numbers with no duplicates.
        var seen = Set<Int64>()
        let entries = store.loadCallerLabels()
            .compactMap { l in l.callKitNumber.map { ($0, l.labelText) } }
            .sorted { $0.0 < $1.0 }
            .filter { seen.insert($0.0).inserted }

        // Always do a full replace: the list is small and labels' counts change.
        if context.isIncremental { context.removeAllIdentificationEntries() }
        for (number, label) in entries {
            context.addIdentificationEntry(withNextSequentialPhoneNumber: number, label: label)
        }
        context.completeRequest()
    }
}
