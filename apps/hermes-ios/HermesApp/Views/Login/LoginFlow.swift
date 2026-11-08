import HermesCore
import SwiftUI

/// Welcome → phone → code → password (only with 2FA). Each step is one field and one button.
struct LoginFlow: View {
    @Environment(HermesStore.self) private var store
    @State private var started = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.22), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    PetSpriteView(animation: petAnimation, size: 132)
                        .padding(.top, 48)
                    Group {
                        switch store.auth {
                        case .waitPhoneNumber where !started: WelcomeStep { withAnimation(.smooth) { started = true } }
                        case .waitPhoneNumber: PhoneStep()
                        case .waitCode(let phone, let via, let length, let next): CodeStep(phone: phone, via: via, length: length, nextVia: next)
                        case .waitPassword(let hint): PasswordStep(hint: hint)
                        case .waitRegistration:
                            StepHeader(title: "No Telegram account", subtitle: "Create one in the Telegram app first, then come back.")
                        default:
                            ProgressView()
                        }
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(.smooth, value: store.auth)
    }

    private var petAnimation: PetAnimation {
        switch store.auth {
        case .waitCode: .waiting
        case .waitPassword: .review
        default: .waving
        }
    }
}

struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            StepHeader(title: "Hermes, in your pocket", subtitle: "Talk to your agent, answer its questions and see what it's up to. Everything goes through your Telegram account.")
            Button(action: next) {
                Text("Continue with Telegram").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct PhoneStep: View {
    @Environment(HermesStore.self) private var store
    @State private var phone = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Your phone number", subtitle: "The one of your Telegram account. Telegram sends you a code.")
            TextField("+33 6 12 34 56 78", text: $phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .focused($focused)
                .onSubmit(submit)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(action: submit) {
                HStack { if busy { ProgressView() }; Text("Next").font(.headline) }.frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || phone.filter(\.isNumber).count < 6)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await store.submitPhone(phone) } catch { self.error = error.localizedDescription }
        }
    }
}

struct CodeStep: View {
    @Environment(HermesStore.self) private var store
    let phone: String
    let via: String
    let length: Int
    let nextVia: String?
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @State private var shake = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Enter the code", subtitle: via == "Telegram"
                       ? "Sent to your Telegram app on another device, for \(phone)."
                       : "Sent by \(via) to \(phone).")
            TextField(String(repeating: "–", count: length), text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .focused($focused)
                .keyframeAnimator(initialValue: 0.0, trigger: shake) { view, x in view.offset(x: x) } keyframes: { _ in
                    KeyframeTrack { SpringKeyframe(12, duration: 0.08); SpringKeyframe(-10, duration: 0.08); SpringKeyframe(6, duration: 0.08); SpringKeyframe(0, duration: 0.1) }
                }
                .onChange(of: code) { _, new in
                    // Typing (or AutoFill pasting) the last digit submits.
                    let digits = new.filter(\.isNumber)
                    if digits != new { code = digits }
                    if digits.count == length { submit() }
                }
            if busy { ProgressView() }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack(spacing: 12) {
                if via == "Telegram", let tg = URL(string: "tg://") {
                    Link(destination: tg) { Label("Open Telegram", systemImage: "paperplane") }
                        .buttonStyle(.bordered)
                }
                if let nextVia {
                    Button("Send by \(nextVia)") { Task { try? await store.resendCode() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await store.submitCode(code)
            } catch {
                self.error = error.localizedDescription
                code = ""
                shake += 1
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

struct PasswordStep: View {
    @Environment(HermesStore.self) private var store
    let hint: String
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Two-step verification", subtitle: hint.isEmpty ? "Your account has a password." : "Your password's hint: \(hint)")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .font(.title3)
                .padding(14)
                .background(.fill.tertiary, in: .rect(cornerRadius: 18))
                .focused($focused)
                .onSubmit(submit)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(action: submit) {
                HStack { if busy { ProgressView() }; Text("Sign In").font(.headline) }.frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || password.isEmpty)
            Link("Forgot your password?", destination: URL(string: "https://telegram.org/faq#q-i-forgot-my-password")!)
                .font(.footnote)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await store.submitPassword(password) } catch { self.error = error.localizedDescription }
        }
    }
}
