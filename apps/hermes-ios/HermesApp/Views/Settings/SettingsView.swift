import HermesCore
import HermesUI
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var confirmLogout = false
    @State private var reinstalling = false
    @AppStorage(CallVoice.defaultsKey) private var voice: CallVoice = .default

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Agent", value: "@\(store.bot?.username ?? store.config.botUsername)")
                LabeledContent("Connection", value: connectionLabel)
                if store.config.demo {
                    Label("Demo data: this build has no Telegram API id.", systemImage: "theatermasks").tone(.secondary)
                }
            }

            Section {
                VoiceModelRow()
                Picker(selection: $voice) {
                    Text("Female").tag(CallVoice.female)
                    Text("Male").tag(CallVoice.male)
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .valuePicker()
            } header: {
                Text("Call mode")
            } footer: {
                Text("Calls run the voice model on this device: it listens and speaks, Hermes answers over Telegram. Without it, calls use Apple's on-device speech.")
            }

            Section {
                HStack {
                    Label("Notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationLabel).tone(.secondary)
                }
                if notifications == .notDetermined {
                    ListActionRow(Text("Turn On Notifications"), detail: nil, systemImage: "bell") {
                        Task { await NotificationService.shared.requestAuthorization(); await refresh() }
                    }
                } else if notifications == .denied {
                    ListActionRow(Text("Open Settings"), detail: nil, systemImage: "gear") {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                if store.config.paidTeam {
                    Text("Hermes pushes notifications and Live Activity updates even when the app is closed. With AirPods, Siri reads them out (Announce Notifications).")
                } else {
                    Text("This build is signed with a free Apple team: notifications arrive while the app runs or refreshes in the background, not when it's closed. A paid team enables push and Siri announcements.")
                }
            }

            Section {
                LabeledContent("Above \(ByteCountFormatter.string(fromByteCount: store.client.uploadLimit, countStyle: .file))", value: store.uploader.serviceName)
            } header: {
                Text("Big files")
            } footer: {
                Text("Files Telegram can't take are uploaded there, and the message carries their link.")
            }

            if !store.delivery.devices.isEmpty {
                Section {
                    ForEach(store.delivery.devices) { d in
                        VGroup(spacing: .xxs) {
                            HStack {
                                Text(d.name).textRole(.body)
                                if d.reachable == false { Text("away").textRole(.caption).tone(.secondary) }
                                Spacer()
                                if let b = d.build { Text(b).textRole(.caption).tone(.secondary) }
                            }
                            if let exp = d.profileExpiry {
                                // Orange within two days of the signature's end.
                                Text("Signature valid until \(exp.formatted(date: .abbreviated, time: .shortened))")
                                    .textRole(.caption).tone(exp.timeIntervalSinceNow < 2 * 86400 ? .warning : .secondary)
                            }
                        }
                    }
                    ListActionRow(Text("Reinstall Now"), detail: nil, systemImage: "arrow.triangle.2.circlepath", isBusy: reinstalling) {
                        reinstalling = true
                        Task {
                            defer { reinstalling = false }
                            do {
                                _ = try await store.sendRequest(.appReinstall)
                                model.showToast("Hermes is rebuilding the app")
                            } catch { model.showToast(error.localizedDescription) }
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("The server re-signs and reinstalls the app before its signature expires.")
                }
            }

            Section {
                Button("Log Out", role: .destructive) { confirmLogout = true }
            }

            Section {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                LabeledContent("Apple team", value: store.config.paidTeam ? String(localized: "Paid") : String(localized: "Free personal"))
                ListActionRow(Text("Copy Diagnostics"), detail: Text("For a call that hears nothing: the permissions, the voice model and the last call's log, no messages."),
                              systemImage: "stethoscope") {
                    Task {
                        UIPasteboard.general.string = await Diagnostics.text(store: store)
                        model.showToast(String(localized: "Diagnostics copied"))
                    }
                }
                .accessibilityIdentifier("settings.diagnostics")
            } header: {
                Text("About")
            }
        }
        .readableGroupedList()
        .navigationTitle("Settings")
        // A page pushed from the chat's menu: inline, as Settings' own sub-pages.
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .confirmationDialog("Log out of Telegram on this device?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { Task { await store.logOut() } }
        }
    }

    private var connectionLabel: String {
        switch store.connection {
        case .ready: String(localized: "Connected")
        case .updating: String(localized: "Updating")
        case .connecting: String(localized: "Connecting")
        case .waitingForNetwork: String(localized: "Waiting for network")
        }
    }

    private var notificationLabel: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: String(localized: "On")
        case .denied: String(localized: "Off")
        default: String(localized: "Not set")
        }
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
