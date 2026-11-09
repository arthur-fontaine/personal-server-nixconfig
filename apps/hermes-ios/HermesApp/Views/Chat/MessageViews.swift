import HermesCore
import HermesUI
import QuickLook
import SwiftUI

/// One message. Hermes' read as a document, full width, no bubble; the owner's are neutral
/// bubbles on the trailing side (design-rules 6, reference/metrics.md).
struct MessageRow: View {
    @Environment(HermesStore.self) private var store
    let message: ChatMessage
    /// False when the message's question is shown as the approval card instead.
    var showsButtons = true
    var highlighted = false
    var onReply: () -> Void = {}
    var onShowOriginal: (MessageID) -> Void = { _ in }
    @State private var selecting = false

    var body: some View {
        VGroup(alignment: message.isOutgoing ? .trailing : .leading, spacing: .s) {
            let reply = store.replyPreview(for: message)
            if message.isOutgoing {
                if !message.displayText.isEmpty {
                    if let reply {
                        ReplyPair { context(reply, above: .owner) } bubble: { bubble }
                    } else {
                        bubble
                    }
                } else if let reply {
                    context(reply, above: .owner)
                }
            } else {
                if let reply { context(reply, above: .hermes) }
                RichMessageText(segments: MessageSegments.make(message.text))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Hermes: \(message.displayText)"))
            }
            ForEach(message.fileLinks, id: \.self) { LinkFileCard(link: $0) }
            if let attachment = message.attachment { AttachmentCard(attachment: attachment) }
            if showsButtons, !message.buttons.isEmpty, !message.isOutgoing { InlineKeyboard(message: message) }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .animation(.smooth, value: bubbleState)
        .replyHighlight(highlighted)
        .swipeToReply(onReply)
        .contextMenu {
            Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button { UIPasteboard.general.string = message.displayText } label: { Label("Copy", systemImage: "doc.on.doc") }
            if !message.displayText.isEmpty {
                Button { Presentation.afterMenu { selecting = true } } label: { Label("Select Text", systemImage: "selection.pin.in.out") }
            }
        }
        .sheet(isPresented: $selecting) { SelectTextSheet(message.displayText) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(message.isOutgoing ? "chat.owner" : "chat.hermes")
    }

    private var bubble: some View {
        UserBubble(message.displayText, state: bubbleState)
            .accessibilityLabel(Text("You: \(message.displayText)"))
    }

    private func context(_ reply: ReplyPreview, above speaker: Speaker) -> some View {
        ReplyContext(ReplyText.kind(reply), above: speaker, accessibilityLabel: ReplyText.label(reply)) { onShowOriginal(reply.originalID) }
            .accessibilityIdentifier("chat.reply")
    }

    private var bubbleState: UserBubble.State {
        switch message.sendState {
        case .pending: .pending
        case .failed: .failed
        default: store.isWaiting(message) ? .waiting : .sent
        }
    }
}

/// A reply's words, in the owner's language (16.1, 16.4).
enum ReplyText {
    static func author(_ a: ReplyPreview.Author) -> Text { a == .you ? Text("You") : Text(verbatim: "Hermes") }

    static func kind(_ r: ReplyPreview) -> ReplyContext.Kind {
        switch r.content {
        case .message(let a, let excerpt): .original(author: author(a), excerpt: Text(verbatim: excerpt))
        case .loading: .loading
        case .deleted: .deleted
        }
    }

    static func label(_ r: ReplyPreview) -> Text {
        switch r.content {
        case .message(.you, let excerpt): Text("Reply to you: \(excerpt)")
        case .message(.hermes, let excerpt): Text("Reply to Hermes: \(excerpt)")
        case .loading: Text("Reply")
        case .deleted: Text("Reply to a deleted message")
        }
    }
}

/// Prose, code and quotes, each paragraph its own view so a streaming edit only re-lays out the
/// paragraph that changed.
struct RichMessageText: View {
    let segments: [MessageSegment]

    var body: some View {
        MessageBlocks {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let a): MessageText(a)
                case .code(let code, _): CodeBlock(code)
                case .quote(let a): QuoteBlock(a)
                }
            }
        }
    }
}

/// A draft Hermes is still writing. The smoother reveals bursts at a steady pace; Stop is the
/// composer's (it replaces Send).
struct StreamingDraftRow: View {
    let draft: StreamingDraft
    @State private var smoother = StreamSmoother()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RichMessageText(segments: MessageSegments.make(
            FormattedText(smoother.shown, entities: draft.text.entities), hidingFileLinks: true))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.draft")
            .task(id: draft.text.text) {
                smoother.update(draft.text.text)
                if reduceMotion { smoother.finish(); return }
                while !smoother.isCaughtUp {
                    smoother.tick()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
    }
}

/// A message's inline keyboard (Telegram buttons): one `ActionRow` per row, the same press as in
/// Telegram.
struct InlineKeyboard: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @State private var busy: String?

    var body: some View {
        let rows = Dictionary(grouping: message.buttons, by: \.row).sorted { $0.key < $1.key }
        VGroup(spacing: .s) {
            ForEach(rows, id: \.key) { _, buttons in
                ActionRow(primary: nil, others: buttons.map { b in
                    Action(id: b.id, verbatim: b.label,
                           emphasis: QuestionOption(id: "", label: b.label).isDestructive ? .destructive : .secondary,
                           isBusy: busy == b.id) { press(b) }
                })
            }
        }
    }

    private func press(_ button: InlineButton) {
        if case .url(let url) = button.action { UIApplication.shared.open(url); return }
        busy = button.id
        Task {
            defer { busy = nil }
            do {
                if let toast = try await store.press(button, on: message), !toast.isEmpty { model.showToast(toast) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }
}

// MARK: - Files

struct LinkFileCard: View {
    let link: FileLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        FileCard(symbol: FileKind.symbol(for: link.displayName), title: link.displayName,
                 detail: Text("Big file, on \(link.service)"), trailingSymbol: "arrow.up.right") { openURL(link.url) }
            .accessibilityLabel(Text("File on \(link.service): \(link.displayName)"))
    }
}

struct AttachmentCard: View {
    @Environment(HermesStore.self) private var store
    let attachment: FileAttachment
    @State private var previewURL: URL?
    @State private var loading = false

    var body: some View {
        FileCard(symbol: FileKind.symbol(for: attachment.name), title: attachment.name,
                 detail: Text(Int64(attachment.size), format: .byteCount(style: .file)),
                 trailingSymbol: loading ? "hourglass" : "arrow.down.circle", action: open)
            .quickLookPreview($previewURL)
    }

    private func open() {
        if let path = attachment.localPath { previewURL = URL(filePath: path); return }
        loading = true
        Task {
            defer { loading = false }
            previewURL = try? await store.client.download(fileID: attachment.fileID)
        }
    }
}

enum FileKind {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "mkv", "avi": "film"
        case "jpg", "jpeg", "png", "heic", "webp", "gif": "photo"
        case "mp3", "m4a", "wav", "aac", "flac": "waveform"
        case "zip", "tar", "gz", "7z", "rar", "dmg": "doc.zipper"
        case "pdf": "doc.richtext"
        case "": "link"
        default: "doc"
        }
    }
}
