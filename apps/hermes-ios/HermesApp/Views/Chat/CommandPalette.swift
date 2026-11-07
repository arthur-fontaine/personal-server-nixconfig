import HermesCore
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
                Section(query.isEmpty ? "Commands" : "Results") {
                    // Model and permission mode already sit in "In this chat" with their values.
                    ForEach(filtered.filter { !query.isEmpty || !shownAbove.contains($0.id) }) { cmd in row(cmd) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search commands")
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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
            Button(confirming?.0.label ?? "Run", role: .destructive) {
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
                if let m = c.model, let selected = m.selected(in: topic) {
                    Button { path.append(.model) } label: {
                        CurrentRow(symbol: "cpu", title: "Model", value: selected.model)
                    }
                    .buttonStyle(.plain)
                }
                if let p = c.permissionMode, let v = p.value, p.set != nil {
                    Button { path.append(.permissions) } label: {
                        CurrentRow(symbol: "checkmark.shield", title: "Permission mode", value: p.options.first { $0.id == v }?.label ?? v)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ cmd: CommandSpec) -> some View {
        Button { run(cmd) } label: {
            HStack(spacing: 14) {
                Image(systemName: cmd.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(cmd.confirm != nil ? Color.red : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background((cmd.confirm != nil ? Color.red : Color.accentColor).opacity(0.12), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(cmd.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(cmd.detail.isEmpty ? (cmd.send ?? cmd.insert ?? "") : cmd.detail)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if cmd.control != nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                else if cmd.insert != nil { Image(systemName: "text.cursor").font(.footnote).foregroundStyle(.tertiary) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(cmd.detail)
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

struct CurrentRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
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
                ForEach(control?.chain ?? []) { m in
                    Button { pick(m) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.model).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text([m.provider, roleLabel(m.role)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if control?.selected(in: topic) == m { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let last = control?.last[topic], last != control?.selected(in: topic) {
                        Text("The last answer came from \(last.model) (a fallback).")
                    }
                    Text(topic == .main ? "Applies to the main chat until you change it." : "Pinned in this sub-chat's rules.")
                }
            }
        }
        .navigationTitle("Model")
    }

    private func roleLabel(_ r: String?) -> String? {
        switch r {
        case "main": "default"
        case "fallback": "fallback"
        case "local": "on the server"
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
            ForEach(p?.options ?? []) { o in
                Button {
                    done()
                    Task { do { try await store.setPermissionMode(o.id) } catch { model.showToast(error.localizedDescription) } }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: o.id == "auto" ? "wand.and.stars" : "hand.raised").foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(o.label).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            if let d = o.description { Text(d).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if p?.value == o.id { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
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
        List(command.options, id: \.self) { option in
            Button {
                done()
                guard let text = command.text(["value": option]) else { return }
                Task { do { try await store.run(command: text, in: topic) } catch { model.showToast(error.localizedDescription) } }
            } label: {
                Text(option.capitalized).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(command.label)
    }
}

/// `sub.new` as a form, inside the palette.
struct SubchatForm: View {
    let done: () -> Void
    var body: some View { NewSubchatFields(onCreated: done) }
}
