import KavachKit
import SwiftUI
import UIKit

/// Sign-in in two steps: name + number → "Text me a code" (`request_sign_in`), then the 6-digit code
/// (`verify_sign_in`). iOS offers the code from Messages above the keyboard (`.oneTimeCode`).
/// Demo numbers (+1 555-555-xxxx) use 000000 when the backend runs with DEMO_MODE=true.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow = SignInFlow(config: .current)
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    switch flow.step {
                    case .details: detailsStep
                    case .code: codeStep
                    }
                }
                .padding(Theme.Space.m)
                .animation(Theme.Motion.animation(reduceMotion: reduceMotion), value: flow.step)
            }
            .kavachScreenBackground()
        }
        .onAppear(perform: refreshFlowConfig)
        #if DEBUG
        .task { await debugPrefill() }
        #endif
    }

    // MARK: Step 1: name and number

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            IconTile("shield.lefthalf.filled", tone: .info, size: 64)
                .padding(.top, Theme.Space.l)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Welcome to \(model.config.displayName)")
                    .font(TypeScale.display).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Check messages and calls, and let your family know when something feels wrong.")
                    .font(.title3).foregroundStyle(Theme.textSecondary)
            }
            if let notice = model.signedOutNotice {
                StatusBanner(tone: .info, systemImage: "arrow.clockwise.circle", title: "Please sign in again", message: notice)
            }
            field("Your first name", placeholder: "For example, Joe", text: $flow.name, content: .givenName, keyboard: .default)
            field("Your mobile number", placeholder: "(555) 555-0101", text: $flow.phone, content: .telephoneNumber, keyboard: .phonePad)
            errorBanner
            Button {
                Task { await flow.sendCode() }
            } label: {
                if flow.busy { ProgressView().tint(Theme.onAccent) } else { Text("Text me a code") }
            }
            .buttonStyle(KavachButtonStyle(.primary))
            .disabled(!flow.canSendCode)

            Text("We'll text a 6-digit code to this number to make sure it's yours. Your number lets your family's replies reach you. We never sell or share it.")
                .font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)

            NavigationLink("Server settings") { ServerSettingsView() }
                .font(TypeScale.callout)
                .frame(minHeight: Theme.minTarget)
        }
    }

    // MARK: Step 2: the code

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            IconTile("message.badge", tone: .info, size: 64)
                .padding(.top, Theme.Space.l)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Enter your code")
                    .font(TypeScale.display).foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("We texted a 6-digit code to \(PhoneNumbers.formatted(flow.phoneE164)).")
                    .font(.title3).foregroundStyle(Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Sign-in code").font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
                TextField("000000", text: Binding(get: { flow.code }, set: { flow.setCode($0) }))
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .kerning(10)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 64)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(flow.error == nil ? Theme.borderStrong.opacity(0.6) : Theme.caution, lineWidth: flow.error == nil ? 1 : 2))
                    .focused($codeFocused)
                    .accessibilityLabel("Sign-in code, 6 digits")
                    .onChange(of: flow.code) { _, code in
                        // Autofilled or fully typed: check it right away.
                        if code.count == SignInFlow.codeLength, !flow.busy { Task { await verify() } }
                    }
            }

            errorBanner

            Button {
                Task { await verify() }
            } label: {
                if flow.busy { ProgressView().tint(Theme.onAccent) } else { Text("Sign in") }
            }
            .buttonStyle(KavachButtonStyle(.primary))
            .disabled(!flow.canVerify)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let wait = flow.secondsUntilResend(at: context.date)
                Button {
                    Task { await flow.resend(); codeFocused = true }
                } label: {
                    Label(wait > 0 ? "Send a new code in \(wait) s" : "Send a new code", systemImage: "arrow.clockwise")
                        .monospacedDigit()
                }
                .buttonStyle(KavachButtonStyle(flow.error?.needsNewCode == true ? .primary : .secondary))
                .disabled(wait > 0 || flow.busy)
            }

            Button("Use a different number") { flow.useDifferentNumber() }
                .buttonStyle(KavachButtonStyle(.quiet))

            Label("Never share this code. \(model.config.displayName) will never call you or ask you to text it back.",
                  systemImage: "lock.shield")
                .font(TypeScale.footnote).foregroundStyle(Theme.textSecondary)
        }
        .onAppear { codeFocused = true }
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = flow.error {
            StatusBanner(tone: error.needsNewCode ? .danger : .caution,
                         systemImage: error.needsNewCode ? "clock.badge.exclamationmark" : "exclamationmark.triangle",
                         title: error.errorDescription ?? "Something went wrong.")
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>, content: UITextContentType,
                       keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label).font(TypeScale.headline).foregroundStyle(Theme.textPrimary)
            TextField(placeholder, text: text)
                .textContentType(content)
                .keyboardType(keyboard)
                .font(.title3)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: 52)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.borderStrong.opacity(0.6)))
                .accessibilityLabel(label)
        }
    }

    private func verify() async {
        guard let signedIn = await flow.verify() else { return }
        await model.completeSignIn(api: signedIn.0, person: signedIn.1)
    }

    /// Server settings may have changed the backend: rebuild the flow (keeping what was typed) before a code is sent.
    private func refreshFlowConfig() {
        guard flow.step == .details, !flow.busy else { return }
        let fresh = SignInFlow(config: model.config)
        fresh.name = flow.name
        fresh.phone = flow.phone
        flow = fresh
    }

    #if DEBUG
    /// Screenshots: `KAVACH_DEBUG_SIGNIN_PHONE`/`_NAME` prefill step 1; `KAVACH_DEBUG_SIGNIN=code` also sends
    /// the code; `KAVACH_DEBUG_SIGNIN_CODE` then enters a code (e.g. a wrong one to show the error).
    private func debugPrefill() async {
        let env = ProcessInfo.processInfo.environment
        guard let phone = env["KAVACH_DEBUG_SIGNIN_PHONE"] else { return }
        flow.phone = phone
        flow.name = env["KAVACH_DEBUG_SIGNIN_NAME"] ?? ""
        guard env["KAVACH_DEBUG_SIGNIN"] == "code" else { return }
        await flow.sendCode()
        if let code = env["KAVACH_DEBUG_SIGNIN_CODE"] { flow.setCode(code); await verify() }
    }
    #endif
}
