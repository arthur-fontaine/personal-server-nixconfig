import HermesCore
import QuickLook
import SwiftUI

/// One message. Hermes' messages read as a document, full width; the owner's are compact
/// tinted bubbles on the right (design.md, "Message rendering").
struct MessageRow: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 8) {
            if message.isOutgoing {
                outgoing
            } else {
                incoming
            }
            ForEach(message.fileLinks, id: \.self) { link in
                LinkFileCard(link: link, outgoing: message.isOutgoing)
            }
            if let attachment = message.attachment {
                AttachmentCard(attachment: attachment, outgoing: message.isOutgoing)
            }
            if !message.buttons.isEmpty, !message.isOutgoing {
                InlineKeyboard(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .contextMenu {
            Button { UIPasteboard.general.string = message.displayText } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var outgoing: some View {
        let text = message.displayText
        if !text.isEmpty {
            HStack(alignment: .bottom, spacing: 6) {
                if case .failed = message.sendState {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 20))
                    .opacity(message.sendState == .pending ? 0.6 : 1)
            }
            // At most ~80 % of the column: the leading inset, not containerRelativeFrame, which
            // measures the whole scroll view, under the floating sidebar too.
            .padding(.leading, 56)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("You: \(text)")
        }
    }

    @ViewBuilder private var incoming: some View {
        RichMessageText(segments: MessageSegments.make(message.text))
            .accessibilityLabel("Hermes: \(message.displayText)")
    }
}

/// Prose, code and quotes, each paragraph its own view so a streaming edit only re-lays out the
/// paragraph that changed.
struct RichMessageText: View {
    let segments: [MessageSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let a):
                    Text(a)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let code, let language):
                    CodeBlock(code: code, language: language)
                case .quote(let a):
                    Text(a)
                        .font(.body).italic()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Capsule().fill(.tint).frame(width: 3) }
                }
            }
        }
    }
}

struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14))
    }
}

/// A draft Hermes is still writing. The smoother reveals bursts at a steady pace.
struct StreamingDraftRow: View {
    @Environment(HermesStore.self) private var store
    let draft: StreamingDraft
    @State private var smoother = StreamSmoother()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RichMessageText(segments: MessageSegments.make(
                FormattedText(smoother.shown, entities: draft.text.entities), hidingFileLinks: true))
            HStack(spacing: 6) {
                TypingDots()
                if draft.canStop {
                    Button { store.stopDraft(in: draft.topic) } label: {
                        Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 6, height: 6).opacity(i == phase ? 0.9 : 0.3)
                }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Hermes is writing")
    }
}

/// A message's inline keyboard (Telegram buttons): the same press as in Telegram.
struct InlineKeyboard: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @State private var busy: String?

    var body: some View {
        let rows = Dictionary(grouping: message.buttons, by: \.row).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.key) { _, buttons in
                    HStack(spacing: 8) {
                        ForEach(buttons) { button in
                            Button {
                                press(button)
                            } label: {
                                HStack {
                                    if busy == button.id { ProgressView().controlSize(.small) }
                                    Text(button.label).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .tint(QuestionOption(id: "", label: button.label).isDestructive ? .red : nil)
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var outgoing: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(link.url) } label: {
            FileCardLabel(symbol: FileKind.symbol(for: link.displayName), title: link.displayName,
                          subtitle: "Big file · \(link.service)", trailing: "arrow.up.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File on \(link.service): \(link.displayName)")
    }
}

struct AttachmentCard: View {
    @Environment(HermesStore.self) private var store
    let attachment: FileAttachment
    var outgoing: Bool
    @State private var previewURL: URL?
    @State private var loading = false

    var body: some View {
        Button(action: open) {
            FileCardLabel(symbol: FileKind.symbol(for: attachment.name), title: attachment.name,
                          subtitle: ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file),
                          trailing: loading ? nil : "arrow.down.circle")
            .overlay(alignment: .trailing) { if loading { ProgressView().padding(.trailing, 14) } }
        }
        .buttonStyle(.plain)
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

struct FileCardLabel: View {
    let symbol: String
    let title: String
    let subtitle: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let trailing { Image(systemName: trailing).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: 360)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .contentShape(.rect)
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

/// "Today 14:02" between messages more than 20 minutes apart (Messages-style).
struct TimeSeparator: View {
    let date: Date

    var body: some View {
        Text(date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
                            : .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}
