import HermesCore
import SwiftUI

/// A private (encrypted) sub-chat stays covered until Face ID. Its passphrase lives in the
/// Keychain behind biometrics; when Hermes has it locked, the app sends `/sub unlock` itself.
struct PrivateGate: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let topic: TopicID
    @State private var askPassphrase = false
    @State private var passphrase = ""
    @State private var remember = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            // Content, not a control: no glass.
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .background(.tint.opacity(0.12), in: .circle)
            Text(ChatTitle.name(topic, store: store)).font(.title2.weight(.semibold))
            Text("This sub-chat is encrypted. Unlock it with \(PrivateVault.biometryName) to read it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(action: unlock) {
                Label(working ? String(localized: "Unlocking…") : String(localized: "Unlock"), systemImage: "faceid").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $askPassphrase) { passphraseSheet }
    }

    private var serverLocked: Bool { !(store.subchat(topic)?.unlocked ?? true) }

    private func unlock() {
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                if PrivateVault.hasPassphrase(topic: topic) {
                    // Reading the Keychain item is the Face ID check.
                    guard let pw = try await PrivateVault.passphrase(topic: topic, reason: String(localized: "Open your private sub-chat")) else { return }
                    if serverLocked { try await store.unlockSubchat(topic, passphrase: pw) }
                    open()
                } else if await PrivateVault.authenticate(reason: String(localized: "Open your private sub-chat")) {
                    if serverLocked { askPassphrase = true } else { open() }
                }
            } catch {
                self.error = String(localized: "Couldn't unlock: \(error.localizedDescription)")
            }
        }
    }

    private func open() {
        withAnimation(.smooth) { _ = model.unlockedTopics.insert(topic) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var passphraseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Passphrase", text: $passphrase).textContentType(.password)
                } footer: {
                    Text("Hermes keeps this sub-chat's memory encrypted. The app sends “/sub unlock” for you and deletes it right after.")
                }
                Section {
                    Toggle("Remember with \(PrivateVault.biometryName)", isOn: $remember)
                }
            }
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { askPassphrase = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") {
                        let pw = passphrase
                        askPassphrase = false
                        passphrase = ""
                        Task {
                            do {
                                try await store.unlockSubchat(topic, passphrase: pw)
                                if remember { try? PrivateVault.save(passphrase: pw, topic: topic) }
                                open()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(passphrase.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Display names for Hermes' presets and expiries (the protocol sends the raw names: `aside`,
/// `1h`…); unknown ones are shown as sent.
enum PresetNames {
    static func name(_ preset: String) -> String {
        switch preset {
        // Keys of their own: "Temp" is also the dashboard's temperature.
        case "aside": String(localized: "preset.aside", defaultValue: "Aside", comment: "Sub-chat preset: a side question")
        case "project": String(localized: "preset.project", defaultValue: "Project", comment: "Sub-chat preset")
        case "secret": String(localized: "preset.secret", defaultValue: "Secret", comment: "Sub-chat preset: encrypted")
        case "temp": String(localized: "preset.temp", defaultValue: "Temp", comment: "Sub-chat preset: temporary")
        default: preset.capitalized
        }
    }

    static func ttl(_ ttl: String) -> String {
        if ttl == "session" { return String(localized: "When the session ends") }
        // "1h", "30m", "2d": a duration in the device's language.
        guard let unit = ttl.last, let n = Int(ttl.dropLast()) else { return ttl }
        let seconds: Int? = switch unit { case "m": n * 60; case "h": n * 3600; case "d": n * 86400; default: nil }
        guard let seconds else { return ttl }
        return String(localized: "\(Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))) after the last message")
    }

    /// Option values of picker commands (reasoning effort).
    static func option(_ value: String) -> String {
        switch value {
        case "none": String(localized: "None", comment: "Reasoning effort")
        case "minimal": String(localized: "Minimal", comment: "Reasoning effort")
        case "low": String(localized: "Low", comment: "Reasoning effort")
        case "medium": String(localized: "Medium", comment: "Reasoning effort")
        case "high": String(localized: "High", comment: "Reasoning effort")
        case "xhigh": String(localized: "Very high", comment: "Reasoning effort")
        default: value.capitalized
        }
    }
}

struct NewSubchatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NewSubchatFields(onCreated: { dismiss() })
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

/// Name + preset, then `/sub new <preset> <name>` in the main chat (protocol §2.4). Presets
/// come from the `controls` slot; the four built-in ones until it arrives.
struct NewSubchatFields: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let onCreated: () -> Void
    @State private var name = ""
    @State private var preset: String?
    @State private var creating = false

    private var presets: [PresetInfo] {
        let p = store.controls.orderedPresets
        return p.isEmpty ? [PresetInfo(name: "aside", isDefault: true), PresetInfo(name: "project"),
                            PresetInfo(name: "secret", encrypted: true), PresetInfo(name: "temp", ttl: "1h")] : p
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("e.g. Taxes 2026", text: $name)
            }
            Section("Kind") {
                ForEach(presets) { p in
                    Button { preset = p.name } label: {
                        HStack(spacing: 12) {
                            Image(systemName: Self.symbol(p)).frame(width: 28).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PresetNames.name(p.name)).font(.body.weight(.medium))
                                Text(Self.blurb(p)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if (preset ?? presets.first?.name) == p.name {
                                Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("New Sub-chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    let chosen = preset ?? presets.first?.name ?? "aside"
                    creating = true
                    Task {
                        defer { creating = false }
                        do {
                            try await store.createSubchat(name: name, preset: chosen)
                            let shown = name.isEmpty ? PresetNames.name(chosen) : name
                            model.showToast("Hermes is opening “\(shown)”")
                            onCreated()
                        } catch { model.showToast(error.localizedDescription) }
                    }
                }
                .disabled(creating)
            }
        }
    }

    static func symbol(_ p: PresetInfo) -> String {
        switch p.name {
        case "aside": "bubble.left.and.bubble.right"
        case "project": "folder"
        case "secret": "lock"
        case "temp": "timer"
        default: p.encrypted ? "lock" : "bubble.left"
        }
    }

    // From docs/hermes.md, "Sub-chats"; other presets describe themselves from their rules.
    static func blurb(_ p: PresetInfo) -> String {
        switch p.name {
        case "aside": String(localized: "A side question that knows everything but leaves no trace once its session ends.")
        case "project": String(localized: "Long-running work in the shared projects memory, apart from daily life.")
        case "secret": String(localized: "Encrypted vault, no main memory, the local model, files and terminal only.")
        case "temp": String(localized: "A throwaway chat on the local model, no tools, gone an hour after its last message.")
        default: p.summary
        }
    }
}
