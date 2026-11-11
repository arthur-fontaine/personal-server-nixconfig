import HermesCore
import HermesUI
import SwiftUI

// Settings › Memory: Hermes' memory, read-only (protocol §4.1). The list of memories, then a
// memory's view as Hermes sees it, each line opening on its two halves, down to a message.

/// Names a memory outside its chat: a private one is "Private chat" with a lock, as everywhere
/// (design-rules 1.4).
enum MemoryNames {
    static func isPrivate(_ v: MemoryVolume, store: HermesStore) -> Bool { v.isPrivate || store.isPrivate(v.chat) }

    static func name(_ v: MemoryVolume, store: HermesStore) -> String {
        if isPrivate(v, store: store) { return String(localized: "Private chat") }
        if v.chat == .main { return String(localized: "Main chat") }
        return store.thread(v.chat)?.name ?? v.name ?? String(localized: "Sub-chat")
    }

    static func symbol(_ v: MemoryVolume, store: HermesStore) -> String {
        isPrivate(v, store: store) ? "lock.fill" : ChatTitle.symbol(v.chat, store: store)
    }

    /// "Messages 2048–3071", "Message 3712": message numbers are names, not quantities (no grouping).
    static func range(_ line: MemoryLine) -> String {
        let first = line.first.formatted(.number.grouping(.never))
        if line.isMessage { return String(localized: "Message \(first)") }
        return String(localized: "Messages \(first)–\(line.last.formatted(.number.grouping(.never)))")
    }

    static func spokenRange(_ line: MemoryLine) -> String {
        let first = line.first.formatted(.number.grouping(.never))
        if line.isMessage { return String(localized: "Message \(first)") }
        return String(localized: "Messages \(first) to \(line.last.formatted(.number.grouping(.never)))")
    }

    static func kind(_ m: MemoryMessage) -> String {
        switch m.kind {
        case .user: String(localized: "You")
        case .hermes: String(localized: "Hermes")
        case .tool: String(localized: "Tool call", comment: "Memory: a tool Hermes ran")
        case .echo: String(localized: "Tool result", comment: "Memory: what a tool returned")
        case .work: String(localized: "Work", comment: "Memory: Hermes' work between messages")
        case .note: String(localized: "Note", comment: "Memory: a note Hermes kept")
        case nil: m.rawKind
        }
    }
}

/// `-memory 0/2048+1024/2048`: the memories, then that chat's view, a line, a message (screenshots).
struct MemoryLink {
    var steps: [String]
    var chat: TopicID? { steps.first.flatMap(TopicID.init) }
    var rest: MemoryLink { MemoryLink(steps: Array(steps.dropFirst())) }

    /// The next step as a line: "2048+1024", or a message index.
    var line: MemoryLine? {
        guard let step = steps.first else { return nil }
        let parts = step.split(separator: "+").compactMap { Int($0) }
        if parts.count == 2 { return MemoryLine(first: parts[0], n: parts[1], text: nil) }
        return parts.first.map { MemoryLine(first: $0, n: 1, text: nil) }
    }

    static var launch: MemoryLink? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-memory"), i + 1 < args.count else { return nil }
        return MemoryLink(steps: args[i + 1].split(separator: "/").map(String.init))
    }
}

/// The Settings row.
struct MemoryRow: View {
    var body: some View {
        NavigationLink { MemoryVolumesView(link: nil) } label: {
            Label("Memory", systemImage: "brain")
        }
        .accessibilityIdentifier("settings.memory")
    }
}

private enum Loading<Value> {
    case loading
    case failed(String)
    case loaded(Value)
}

/// The system's loading and error states, for a screen that loads once.
private struct LoadState<Value, Content: View>: View {
    let state: Loading<Value>
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Read the Memory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        case .loaded(let value):
            content(value)
        }
    }
}

struct MemoryVolumesView: View {
    @Environment(HermesStore.self) private var store
    let link: MemoryLink?
    @State private var state: Loading<[MemoryVolume]> = .loading
    @State private var linked: TopicID?

    var body: some View {
        LoadState(state: state, retry: { Task { await load() } }) { volumes in
            List {
                Section {
                    ForEach(volumes) { row($0) }
                } footer: {
                    Text("What Hermes remembers of each chat. Older messages are summarized more coarsely; open a line to read what it covers. Nothing here changes the memory.")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        }
        .readableGroupedList()
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $linked) { chat in
            MemoryLevelView(chat: chat, line: nil, link: link?.rest)
        }
        .task {
            await load()
            if let chat = link?.chat { linked = chat }
        }
    }

    @ViewBuilder private func row(_ v: MemoryVolume) -> some View {
        let label = Label {
            VGroup(spacing: .xxs) {
                Text(MemoryNames.name(v, store: store))
                if v.locked {
                    Text("Locked: unlock its chat to read it").textRole(.footnote).tone(.secondary)
                } else if let count = v.messages {
                    Text("^[\(count) message](inflect: true)").textRole(.footnote).tone(.secondary)
                }
            }
        } icon: {
            Image(systemName: MemoryNames.symbol(v, store: store)).accessibilityHidden(true)
        }
        if v.locked {
            // Never the passphrase here (the brief): the chat unlocks it.
            label.accessibilityElement(children: .combine)
        } else {
            NavigationLink { MemoryLevelView(chat: v.chat, line: nil, link: nil) } label: { label }
                .accessibilityIdentifier("memory.volume.\(v.chat)")
        }
    }

    private func load() async {
        do { state = .loaded(try await store.memoryVolumes()) }
        catch { state = .failed(error.localizedDescription) }
    }
}

/// One level of a memory: its view (`line == nil`, paged as the server sends it) or a line's two
/// halves. A private memory stays behind Face ID, as its chat does.
struct MemoryLevelView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let chat: TopicID
    let line: MemoryLine?
    let link: MemoryLink?
    @State private var state: Loading<[MemoryLine]> = .loading
    @State private var next: Int?
    @State private var pageError: String?
    @State private var linked: MemoryLine?

    private var isPrivate: Bool { store.isPrivate(chat) }
    private var gated: Bool { isPrivate && !model.unlockedTopics.contains(chat) }

    var body: some View {
        Group {
            if gated {
                PrivateGate(topic: chat)
            } else {
                LoadState(state: state, retry: { Task { await load() } }) { lines in
                    List {
                        Section {
                            ForEach(lines) { row($0) }
                            if next != nil { moreRow }
                        } footer: {
                            if line == nil { Text("What Hermes sees of this chat now, oldest first.") }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { await load() }
                }
                .task(id: chat) { await load() }
            }
        }
        .readableGroupedList()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $linked) { destination($0, link: link?.rest) }
    }

    private var title: String {
        if let line { return MemoryNames.range(line) }
        return ChatTitle.title(chat, store: store, unlocked: model.unlockedTopics.contains(chat), active: scenePhase == .active)
    }

    private func row(_ l: MemoryLine) -> some View {
        NavigationLink { destination(l, link: nil) } label: {
            VGroup(spacing: .xxs) {
                Text(MemoryNames.range(l)).textRole(.subheadline).tone(.secondary)
                if let text = l.text {
                    Text(text)
                } else {
                    Text("Not summarized yet").tone(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(MemoryNames.spokenRange(l)))
        .accessibilityValue(Text(l.text ?? String(localized: "Not summarized yet")))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("memory.line.\(l.id)")
    }

    @ViewBuilder private func destination(_ l: MemoryLine, link: MemoryLink?) -> some View {
        if l.isMessage { MemoryMessageView(chat: chat, index: l.first) }
        else { MemoryLevelView(chat: chat, line: l, link: link) }
    }

    @ViewBuilder private var moreRow: some View {
        if let pageError {
            ListActionRow(Text("Load More"), detail: Text(pageError), systemImage: "arrow.clockwise") {
                Task { await loadMore() }
            }
        } else {
            HGroup(spacing: .xs) {
                ProgressView()
                Text("Loading more…").tone(.secondary)
            }
            .task { await loadMore() }
        }
    }

    private func load() async {
        guard !gated else { return }
        do {
            if let line {
                state = .loaded(try await store.memoryHalves(chat: chat, of: line))
                next = nil
            } else {
                let page = try await store.memoryView(chat: chat)
                state = .loaded(page.lines)
                next = page.next
            }
            pageError = nil
            if let target = link?.line, linked == nil { linked = target }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadMore() async {
        guard let after = next, case .loaded(let lines) = state else { return }
        do {
            let page = try await store.memoryView(chat: chat, after: after)
            state = .loaded(lines + page.lines)
            next = page.next
            pageError = nil
        } catch {
            pageError = error.localizedDescription
        }
    }
}

/// One message of the log: who, when, and its text.
struct MemoryMessageView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let chat: TopicID
    let index: Int
    @State private var state: Loading<MemoryMessage> = .loading

    var body: some View {
        Group {
            if store.isPrivate(chat) && !model.unlockedTopics.contains(chat) {
                PrivateGate(topic: chat)
            } else {
                LoadState(state: state, retry: { Task { await load() } }) { m in
                    List {
                        Section {
                            LabeledContent("From", value: MemoryNames.kind(m))
                            if let date = m.date {
                                LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        Section {
                            Text(m.text)
                                .textRole(m.kind == .tool || m.kind == .echo ? .code : .body)
                                .textSelection(.enabled)
                        } header: {
                            Text("Text")
                        } footer: {
                            if m.isCut { Text("Only the beginning of this long message is shown.") }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
                .task { await load() }
            }
        }
        .readableGroupedList()
        .navigationTitle(MemoryNames.range(MemoryLine(first: index, n: 1, text: nil)))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        do { state = .loaded(try await store.memoryMessage(chat: chat, index: index)) }
        catch { state = .failed(error.localizedDescription) }
    }
}
