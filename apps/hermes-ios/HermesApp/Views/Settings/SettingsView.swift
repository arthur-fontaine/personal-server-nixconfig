import HermesCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var confirmLogout = false
    @State private var reinstalling = false

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Agent", value: "@\(store.bot?.username ?? store.config.botUsername)")
                LabeledContent("Connection", value: connectionLabel)
                if store.config.demo {
                    Label("Demo data: this build has no Telegram API id.", systemImage: "theatermasks").foregroundStyle(.secondary)
                }
            }

            Section {
                VoiceModelRow()
            } header: {
                Text("Call mode")
            } footer: {
                Text("Calls run the voice model on this device: it listens and speaks, Hermes answers over Telegram. Without it, calls use Apple's on-device speech.")
            }

            Section {
                HStack {
                    Label("Notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationLabel).foregroundStyle(.secondary)
                }
                if notifications == .notDetermined {
                    Button("Turn On Notifications") { Task { await NotificationService.shared.requestAuthorization(); await refresh() } }
                } else if notifications == .denied {
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(store.config.paidTeam
                     ? "Hermes pushes notifications and Live Activity updates even when the app is closed. With AirPods, Siri reads them out (Announce Notifications)."
                     : "This build is signed with a free Apple team: notifications arrive while the app runs or refreshes in the background, not when it's closed. A paid team enables push and Siri announcements.")
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
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(d.name).font(.body.weight(.medium))
                                if d.reachable == false { Text("away").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if let b = d.build { Text(b).font(.caption).foregroundStyle(.secondary) }
                            }
                            if let exp = d.profileExpiry {
                                Text("Signature valid until \(exp.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(exp.timeIntervalSinceNow < 2 * 86400 ? .orange : .secondary)
                            }
                        }
                    }
                    Button {
                        reinstalling = true
                        Task {
                            defer { reinstalling = false }
                            do {
                                _ = try await store.sendRequest(.appReinstall)
                                model.showToast("Hermes is rebuilding the app")
                            } catch { model.showToast(error.localizedDescription) }
                        }
                    } label: {
                        HStack { Label("Reinstall Now", systemImage: "arrow.triangle.2.circlepath"); if reinstalling { Spacer(); ProgressView() } }
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
                LabeledContent("Apple team", value: store.config.paidTeam ? "Paid" : "Free personal")
            }
        }
        // A readable column in a wide window, as Settings does on iPad.
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Settings")
        .task { await refresh() }
        .confirmationDialog("Log out of Telegram on this device?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { Task { await store.logOut() } }
        }
    }

    private var connectionLabel: String {
        switch store.connection {
        case .ready: "Connected"
        case .updating: "Updating"
        case .connecting: "Connecting"
        case .waitingForNetwork: "Waiting for network"
        }
    }

    private var notificationLabel: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Not set"
        }
    }

    private func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
