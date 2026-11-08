import KavachKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayPreferences) private var prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !prefs.homeShowsOnlyActions {
                    StatusCard()
                }
                ForEach(model.pendingVerifications) { v in PendingVerificationCard(verification: v) }
                actions
                if !prefs.homeShowsOnlyActions {
                    ThisWeekSection(limit: 3)
                }
                if let problem = model.connectionProblem {
                    Label(problem, systemImage: "wifi.exclamationmark")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel("Connection problem: \(problem)")
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.person.map { "Hi, \($0.displayName)" } ?? model.config.displayName)
        .refreshable { await model.refresh() }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            BigActionButton("Check a message", systemImage: "text.magnifyingglass",
                            subtitle: "Paste a text or choose a screenshot") { model.route = .check(prefill: nil) }
            BigActionButton("I'm on a call", systemImage: "phone.fill",
                            subtitle: "Open Call Companion") { model.route = .companion }
            BigActionButton("I need help", systemImage: "hand.raised.fill",
                            subtitle: "Something happened, or I shared something") { model.route = .needHelp }
        }
    }
}

struct StatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            if let active = model.activeIncident {
                let sev = active.severityLevel
                Label(sev == .critical ? "Act now" : "Please follow up", systemImage: "exclamationmark.shield.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.color(for: sev))
                let left = model.steps(for: active.id).filter { !$0.done }.count
                Text("\(left) step\(left == 1 ? "" : "s") left to stay safe.").font(.body)
                Button("See my steps") { model.route = .actNow(incidentId: active.id) }
                    .buttonStyle(KavachButtonStyle(prominent: true, tint: Theme.color(for: sev)))
            } else {
                Label("You're protected", systemImage: "checkmark.shield.fill")
                    .font(.title2.weight(.bold)).foregroundStyle(Theme.safe)
                let n = model.scamsStoppedThisWeek
                Text(n == 0 ? "No scams got through this week." : "\(n) scam\(n == 1 ? "" : "s") stopped this week.")
                    .font(.body)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "This week": recent checks, active campaigns, latest briefing.
struct ThisWeekSection: View {
    @Environment(AppModel.self) private var model
    var limit: Int = .max
    @State private var requested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This week").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)

            if let b = model.briefings.first {
                Card {
                    Label("Your weekly briefing", systemImage: "newspaper.fill").font(.headline)
                    Text(b.summaryText)
                    Button {
                        Speaker.shared.speak(b.spokenText.isEmpty ? b.summaryText : b.spokenText)
                    } label: { Label("Read aloud", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(KavachButtonStyle())
                }
            } else {
                Card {
                    Label("Weekly briefing", systemImage: "newspaper").font(.headline)
                    Text(requested ? "Your briefing is on its way. It will show here and arrive by text."
                                   : "A short summary of your week arrives Sunday evening.")
                    if !requested {
                        Button("Get my briefing now") {
                            Task { requested = await model.run { try await $0.requestBriefing(personId: model.personId) } }
                        }
                        .buttonStyle(KavachButtonStyle())
                    }
                }
            }

            if !model.checksThisWeek.isEmpty {
                Text("Recent checks").font(.headline)
                ForEach(model.checksThisWeek.prefix(limit)) { c in
                    Card {
                        VerdictBadge(c.verdictKind, large: false)
                        Text(c.reason).font(.body)
                        Text(c.contentRedacted).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !model.campaigns.isEmpty {
                Text("Scams going around").font(.headline)
                ForEach(model.campaigns.prefix(limit)) { c in
                    Card {
                        Text(c.title).font(.headline)
                        Text(c.tacticSummary).font(.body)
                        Text("\(c.weeklyReports) reports this week").font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct ThisWeekView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ThisWeekSection()
                if !model.incidents.isEmpty {
                    Text("Your reports").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                    ForEach(model.incidents) { inc in
                        Card {
                            HStack {
                                Text(entryLabel(inc.entryPoint)).font(.headline)
                                Spacer()
                                SeverityBadge(inc.severityLevel)
                            }
                            if !inc.claimedIdentity.isEmpty { Text("Said they were: \(inc.claimedIdentity)") }
                            if let d = inc.createdAt.date {
                                Text(d, style: .relative).font(.footnote).foregroundStyle(.secondary)
                            }
                            if !model.steps(for: inc.id).isEmpty {
                                Button("Open steps") { model.route = .actNow(incidentId: inc.id) }
                                    .buttonStyle(KavachButtonStyle())
                            } else if inc.severityLevel == .unrated && !inc.isResolved {
                                Button("Answer the questions") { model.route = .interview(incidentId: inc.id) }
                                    .buttonStyle(KavachButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("This week")
        .refreshable { await model.refresh() }
    }

    private func entryLabel(_ e: String) -> String {
        switch e {
        case "companion": "During a call"
        case "report_swipe": "Reported call"
        case "hotline": "Hotline call"
        case "imessage": "Text to \(model.config.displayName)"
        default: "From the app"
        }
    }
}

/// Trusted Sender Check on the relative's phone (also delivered by push).
struct PendingVerificationCard: View {
    @Environment(AppModel.self) private var model
    let verification: Verification
    @State private var busy = false

    var body: some View {
        Card {
            Label("Family check", systemImage: "person.badge.shield.checkmark.fill").font(.headline)
            Text("Someone asked a family member for something using your name. Did you send it?")
            HStack {
                Button("Yes, it was me") {
                    Task {
                        busy = true
                        await PushRegistrar.answerTrustedSender(verificationId: verification.id, confirmed: true)
                        busy = false
                    }
                }
                .buttonStyle(KavachButtonStyle(prominent: true))
                .accessibilityHint("Needs Face ID or your passcode")
                Button("No, not me") {
                    Task {
                        busy = true
                        await PushRegistrar.answerTrustedSender(verificationId: verification.id, confirmed: false)
                        busy = false
                    }
                }
                .buttonStyle(KavachButtonStyle())
            }
            .disabled(busy)
        }
    }
}
