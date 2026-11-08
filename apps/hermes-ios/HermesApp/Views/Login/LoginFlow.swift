import HermesCore
import HermesUI
import SwiftUI

/// Welcome → phone → code → password (only with 2FA). Each step is one field and one button, on
/// HermesUI's `OnboardingPage` (Apple's welcome-screen layout): the pet in the state of the step.
struct LoginFlow: View {
    @Environment(HermesStore.self) private var store
    @State private var started = false

    var body: some View {
        Group {
            switch store.auth {
            case .waitPhoneNumber where !started: WelcomeStep(pet: pet) { withAnimation(.smooth) { started = true } }
            case .waitPhoneNumber: PhoneStep(pet: pet)
            case .waitCode(let phone, let via, let length, let next): CodeStep(pet: pet, phone: phone, via: via, length: length, nextVia: next)
            case .waitPassword(let hint): PasswordStep(pet: pet, hint: hint)
            case .waitRegistration:
                OnboardingPage(title: Text("No Telegram account"), message: Text("Create one in the Telegram app first, then come back.")) {
                    pet
                } fields: {
                    EmptyView()
                } actions: {
                    EmptyView()
                }
            default:
                ProgressView()
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
        .animation(.smooth, value: store.auth)
    }

    private var pet: some View {
        PetSpriteView(animation: petAnimation, size: .hero)
    }

    private var petAnimation: PetAnimation {
        switch store.auth {
        case .waitCode: .waiting
        case .waitPassword: .review
        default: .waving
        }
    }
}

struct WelcomeStep<Pet: View>: View {
    let pet: Pet
    let next: () -> Void

    var body: some View {
        OnboardingPage(title: Text("Hermes, in your pocket"),
                       message: Text("Talk to your agent, answer its questions and see what it's up to. Everything goes through your Telegram account.")) {
            pet
        } fields: {
            EmptyView()
        } actions: {
            PrimaryButton("Continue with Telegram", fullWidth: true, action: next)
        }
    }
}

struct PhoneStep<Pet: View>: View {
    @Environment(HermesStore.self) private var store
    let pet: Pet
    @State private var phone = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingPage(title: Text("Your phone number"), message: Text("The one of your Telegram account. Telegram sends you a code.")) {
            pet
        } fields: {
            TextField("+33 6 12 34 56 78", text: $phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                .multilineTextAlignment(.center)
                .inputField()
                .focused($focused)
                .onSubmit(submit)
            if let error { Text(error).textRole(.footnote).tone(.destructive) }
        } actions: {
            PrimaryButton("Next", isBusy: busy, fullWidth: true, action: submit)
                .disabled(phone.filter(\.isNumber).count < 6)
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

struct CodeStep<Pet: View>: View {
    @Environment(HermesStore.self) private var store
    let pet: Pet
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
        OnboardingPage(title: Text("Enter the code"), message: via == "Telegram"
                       ? Text("Sent to your Telegram app on another device, for \(phone).")
                       : Text("Sent by \(via) to \(phone).")) {
            pet
        } fields: {
            TextField(String(repeating: "–", count: length), text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .inputField()
                .focused($focused)
                .shake(on: shake)
                .onChange(of: code) { _, new in
                    // Typing (or AutoFill pasting) the last digit submits.
                    let digits = new.filter(\.isNumber)
                    if digits != new { code = digits }
                    if digits.count == length { submit() }
                }
            if busy { ProgressView() }
            if let error { Text(error).textRole(.footnote).tone(.destructive) }
        } actions: {
            if via == "Telegram", let tg = URL(string: "tg://") {
                Link(destination: tg) { Label("Open Telegram", systemImage: "paperplane") }
            }
            if let nextVia {
                Button("Send by \(nextVia)") { Task { try? await store.resendCode() } }
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

struct PasswordStep<Pet: View>: View {
    @Environment(HermesStore.self) private var store
    let pet: Pet
    let hint: String
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingPage(title: Text("Two-step verification"),
                       message: hint.isEmpty ? Text("Your account has a password.") : Text("Your password's hint: \(hint)")) {
            pet
        } fields: {
            SecureField("Password", text: $password)
                .textContentType(.password)
                .inputField()
                .focused($focused)
                .onSubmit(submit)
            if let error { Text(error).textRole(.footnote).tone(.destructive) }
        } actions: {
            PrimaryButton("Sign In", isBusy: busy, fullWidth: true, action: submit)
                .disabled(password.isEmpty)
            Link("Forgot your password?", destination: URL(string: "https://telegram.org/faq#q-i-forgot-my-password")!)
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
