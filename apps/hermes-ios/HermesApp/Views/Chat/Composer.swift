import HermesCore
import HermesUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the composer holds, owned by the chat screen so what it presents (the palette, the file
/// importer) can write into it. A reference: the screen doesn't read it, so typing doesn't
/// re-evaluate the transcript.
@Observable @MainActor
final class ComposerDraft {
    var text = ""
    var files: [PendingFile] = []

    /// Copies the file out of the picker's sandbox (the upload may outlive the security scope).
    func attach(_ url: URL, securityScoped: Bool) -> Bool {
        let scoped = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            files.append(PendingFile(url: dest, size: size))
            return true
        } catch {
            return false
        }
    }
}

/// The composer: `ComposerBar` with the attach menu, files waiting and uploads above it. Files
/// over Telegram's cap say where they'll go before sending. What its menu opens is presented by
/// the chat screen: a sheet attached inside the bar was asked for while the menu left and was
/// mostly dropped on the iPhone.
struct Composer: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let topic: TopicID
    @Bindable var draft: ComposerDraft
    var focused: FocusState<Bool>.Binding
    @Binding var replyingTo: ChatMessage?
    let onAttachFile: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var sending = false
    @State private var lastTyping = Date.distantPast

    var body: some View {
        VGroup(spacing: .xs) {
            ForEach(store.uploads.values.sorted { $0.name < $1.name }, id: \.name) { u in
                UploadBar(title: Text("Uploading \(u.name) to \(u.service)"), progress: Self.progress(u.fraction))
            }
            if !draft.files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HGroup(spacing: .xs) {
                        ForEach(draft.files) { f in
                            let size = f.size.formatted(.byteCount(style: .file))
                            AttachmentChip(symbol: FileKind.symbol(for: f.url.lastPathComponent), name: f.url.lastPathComponent,
                                           detail: f.size > store.client.uploadLimit ? String(localized: "\(size), via \(store.uploader.serviceName)") : size) {
                                draft.files.removeAll { $0.id == f.id }
                            }
                        }
                    }
                }
            }
            if let original = replyingTo {
                let excerpt = ReplyPreview.excerpt(of: original)
                ReplyChip(author: ReplyText.author(original.isOutgoing ? .you : .hermes), excerpt: Text(verbatim: excerpt),
                          accessibilityLabel: original.isOutgoing ? Text("Replying to you: \(excerpt)") : Text("Replying to Hermes: \(excerpt)")) {
                    replyingTo = nil
                }
                .accessibilityIdentifier("composer.reply")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposerBar(text: $draft.text, placeholder: Text(placeholder), action: composerAction, focus: focused,
                        onSend: send, onStop: { store.stopDraft(in: topic) }) {
                Button { model.showCommands = true } label: { Label("Commands", systemImage: "command") }
                Divider()
                Button(action: onAttachFile) { Label("File", systemImage: "doc") }
                PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                    Label("Photos & Videos", systemImage: "photo.on.rectangle")
                }
            }
            .onChange(of: draft.text) { old, new in
                // "/" on an empty composer opens the palette instead of Telegram's raw commands.
                if old.isEmpty, new == "/" { draft.text = ""; model.showCommands = true }
                typingPing()
            }
        }
        .onChange(of: photos) { _, items in
            Task {
                for item in items {
                    if let movie = try? await item.loadTransferable(type: PickedFile.self) { addFile(movie.url, securityScoped: false) }
                }
                photos = []
            }
        }
    }

    private static func progress(_ fraction: Double) -> Progress {
        let p = Progress(totalUnitCount: 1000)
        p.completedUnitCount = Int64(fraction * 1000)
        return p
    }

    /// Stop replaces Send while Hermes writes here and the draft can be stopped.
    private var composerAction: ComposerAction {
        if sending { return .sending }
        if draft.text.isEmpty, draft.files.isEmpty, store.drafts[topic]?.canStop == true { return .stop }
        return .send(enabled: canSend)
    }

    /// Short as Messages' own, so it fits at accessibility sizes.
    private var placeholder: String { String(localized: "Message") }

    private var canSend: Bool {
        !sending && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.files.isEmpty)
    }

    private func addFile(_ url: URL, securityScoped: Bool) {
        if !draft.attach(url, securityScoped: securityScoped) { model.showToast("Couldn't attach \(url.lastPathComponent)") }
    }

    private func typingPing() {
        guard Date().timeIntervalSince(lastTyping) > 4, !draft.text.isEmpty else { return }
        lastTyping = .now
        store.userIsTyping(in: topic)
    }

    private func send() {
        let body = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = draft.files.map(\.url)
        let replyTo = replyingTo?.id
        draft.text = ""
        draft.files = []
        replyingTo = nil
        sending = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            defer {
                sending = false
                for u in urls { try? FileManager.default.removeItem(at: u) }
            }
            do {
                try await store.send(body, in: topic, files: urls, replyTo: replyTo)
            } catch {
                draft.text = body
                model.showToast(error.localizedDescription)
            }
        }
    }
}

struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let size: Int64
}

/// A photo or video from the library, as a file (videos can be many GB: never in memory).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dest = FileManager.default.temporaryDirectory.appending(path: "picked-\(UUID().uuidString.prefix(8))-\(received.file.lastPathComponent)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedFile(url: dest)
        }
    }
}
