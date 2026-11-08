import HermesCore
import HermesUI
import SwiftUI

/// Hermes' slash commands, curated and made native (protocol §2.4): the model as a menu, the
/// permission mode as a picker showing the current value, a new sub-chat as a form, pickers for
/// option commands; the rest one tap (or prefilled in the composer for those that need text).
struct CommandPalette: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let topic: TopicID
    var filter: String = ""
    /// Puts text in the composer (commands that need the owner's words).
    var insert: (String) -> Void

    @State private var query = ""
    @State private var confirming: (CommandSpec, String)?
    @State private var path: [Destination] = []

    enum Destination: Hashable {
        case model, permissions, picker(String), subchatForm
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if query.isEmpty { current }
                Section(query.isEmpty ? String(localized: "Commands") : String(localized: "Results")) {
                    // Model and permission mode already sit in "In this chat" with their values.
                    ForEach(filtered.filter { !query.isEmpty || !shownAbove.contains($0.id) }) { cmd in row(cmd) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search commands")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            .navigationDestination(for: Destination.self) { d in
                switch d {
                case .model: ModelMenu(topic: topic) { dismiss() }
                case .permissions: PermissionPicker { dismiss() }
                case .picker(let id): OptionPicker(command: store.controls.commands.first { $0.id == id }!, topic: topic) { dismiss() }
                case .subchatForm: SubchatForm { dismiss() }
                }
            }
            .overlay {
                if store.controls.commands.isEmpty {
                    ContentUnavailableView("No commands yet", systemImage: "command", description: Text("Hermes shares them once connected."))
                }
            }
        }
        .onAppear { query = filter }
        .confirmationDialog(confirming?.0.confirm ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button(confirming?.0.label ?? String(localized: "Run"), role: .destructive) {
                if let (_, text) = confirming { send(text) }
            }
        }
        // A half sheet on iPhone; a form-sized sheet on iPad, where a half height shows three rows.
        // (The idiom, not the size class: inside a form sheet the size class is always compact.)
        .presentationDetents(UIDevice.current.userInterfaceIdiom == .pad ? [.large] : [.medium, .large])
        .presentationSizing(.form)
    }

    private var shownAbove: Set<String> {
        var ids: Set<String> = []
        if store.controls.model?.selected(in: topic) != nil { ids.insert("model") }
        if store.controls.permissionMode?.value != nil { ids.insert("permissions") }
        return ids
    }

    private var commands: [CommandSpec] { store.controls.commands(for: store.commandContext(topic)) }

    private var filtered: [CommandSpec] {
        let q = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.label.lowercased().contains(q) || $0.id.contains(q) || ($0.send ?? $0.insert ?? "").contains(q) || $0.detail.lowercased().contains(q) }
    }

    /// The values in force, at a glance: what the native controls change.
    @ViewBuilder private var current: some View {
        let c = store.controls
        if c.model != nil || c.permissionMode?.value != nil {
            Section("In this chat") {
                // The system's value row: label, value in secondary, the disclosure chevron.
                if let m = c.model, let selected = m.selected(in: topic) {
                    NavigationLink(value: Destination.model) {
                        LabeledContent { Text(selected.model) } label: { Label("Model", systemImage: "cpu") }
                    }
                }
                if let p = c.permissionMode, let v = p.value, p.set != nil {
                    NavigationLink(value: Destination.permissions) {
                        LabeledContent { Text(p.options.first { $0.id == v }?.label ?? v) } label: { Label("Permission Mode", systemImage: "checkmark.shield") }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ cmd: CommandSpec) -> some View {
        let detail = Text(cmd.detail.isEmpty ? (cmd.send ?? cmd.insert ?? "") : cmd.detail)
        if let destination = Self.destination(cmd) {
            NavigationLink(value: destination) {
                Label {
                    VGroup(spacing: .xxs) {
                        Text(cmd.label)
                        detail.textRole(.footnote).tone(.secondary)
                    }
                } icon: {
                    Image(systemName: cmd.symbol).tone(.secondary).accessibilityHidden(true)
                }
            }
        } else {
            ListActionRow(Text(cmd.label), detail: detail, systemImage: cmd.symbol,
                          destructive: cmd.confirm != nil, fillsComposer: cmd.insert != nil) { run(cmd) }
                .accessibilityHint(cmd.detail)
        }
    }

    static func destination(_ cmd: CommandSpec) -> Destination? {
        switch cmd.control {
        case "model": .model
        case "permission_mode": .permissions
        case "subchat_form": .subchatForm
        case "picker": .picker(cmd.id)
        default: nil
        }
    }

    private func run(_ cmd: CommandSpec) {
        switch cmd.control {
        case "model": path.append(.model); return
        case "permission_mode": path.append(.permissions); return
        case "subchat_form": path.append(.subchatForm); return
        case "picker": path.append(.picker(cmd.id)); return
        default: break
        }
        if let ins = cmd.insert {
            insert(ins)
            dismiss()
            return
        }
        guard let text = cmd.text() else { return }
        if cmd.confirm != nil { confirming = (cmd, text) } else { send(text) }
    }

    private func send(_ text: String) {
        dismiss()
        Task {
            do { try await store.run(command: text, in: topic) } catch { model.showToast(error.localizedDescription) }
        }
    }
}

/// The model menu: the server's chain, the one in force checked, what answered last noted.
struct ModelMenu: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let topic: TopicID
    let done: () -> Void

    var body: some View {
        let control = store.controls.model
        List {
            Section {
                // The system's choice of one: picking sets the model and closes the palette.
                Picker(selection: Binding(get: { control?.selected(in: topic)?.id }, set: { id in
                    if let m = control?.chain.first(where: { $0.id == id }) { pick(m) }
                })) {
                    ForEach(control?.chain ?? []) { m in
                        VGroup(spacing: .xxs) {
                            Text(m.model)
                            Text([m.provider, roleLabel(m.role)].compactMap { $0 }.joined(separator: ", "))
                                .textRole(.footnote).tone(.secondary)
                        }
                        .tag(Optional(m.id))
                    }
                } label: {
                    Text("Model")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                VGroup(spacing: .xs) {
                    if let last = control?.last[topic], last != control?.selected(in: topic) {
                        Text("The last answer came from \(last.model) (a fallback).")
                    }
                    Text(topic == .main ? String(localized: "Applies to the main chat until you change it.") : String(localized: "Pinned in this sub-chat's rules."))
                }
            }
        }
        .navigationTitle("Model")
    }

    private func roleLabel(_ r: String?) -> String? {
        switch r {
        case "main": String(localized: "default", comment: "Model role")
        case "fallback": String(localized: "fallback", comment: "Model role")
        case "local": String(localized: "on the server", comment: "Model role")
        default: r
        }
    }

    private func pick(_ m: ModelRef) {
        done()
        Task {
            do { try await store.setModel(m, in: topic) } catch { model.showToast(error.localizedDescription) }
        }
    }
}

struct PermissionPicker: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let done: () -> Void

    var body: some View {
        let p = store.controls.permissionMode
        List {
            Picker(selection: Binding(get: { p?.value }, set: { id in
                guard let id else { return }
                done()
                Task { do { try await store.setPermissionMode(id) } catch { model.showToast(error.localizedDescription) } }
            })) {
                ForEach(p?.options ?? []) { o in
                    Label {
                        VGroup(spacing: .xxs) {
                            Text(o.label)
                            if let d = o.description { Text(d).textRole(.footnote).tone(.secondary) }
                        }
                    } icon: {
                        Image(systemName: o.id == "auto" ? "wand.and.stars" : "hand.raised").accessibilityHidden(true)
                    }
                    .tag(Optional(o.id))
                }
            } label: {
                Text("Permission Mode")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .navigationTitle("Permission Mode")
    }
}

struct OptionPicker: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let command: CommandSpec
    let topic: TopicID
    let done: () -> Void

    var body: some View {
        List {
            Picker(selection: Binding<String?>(get: { nil }, set: { option in
                guard let option, let text = command.text(["value": option]) else { return }
                done()
                Task { do { try await store.run(command: text, in: topic) } catch { model.showToast(error.localizedDescription) } }
            })) {
                ForEach(command.options, id: \.self) { option in
                    Text(PresetNames.option(option)).tag(Optional(option))
                }
            } label: {
                Text(command.label)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .navigationTitle(command.label)
    }
}

/// `sub.new` as a form, inside the palette.
struct SubchatForm: View {
    let done: () -> Void
    var body: some View { NewSubchatFields(onCreated: done) }
}
