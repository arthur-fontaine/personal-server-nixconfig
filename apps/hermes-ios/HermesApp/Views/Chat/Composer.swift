import HermesCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The floating glass composer. Files over Telegram's cap say where they'll go before sending.
struct Composer: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let topic: TopicID
    var focused: FocusState<Bool>.Binding
    @State private var text = ""
    @State private var files: [PendingFile] = []
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var sending = false
    @State private var lastTyping = Date.distantPast

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 8) {
                ForEach(store.uploads.values.sorted { $0.name < $1.name }, id: \.name) { u in
                    UploadRow(upload: u)
                }
                if !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(files) { f in fileChip(f) }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        Button { model.showCommands = true } label: { Label("Commands", systemImage: "command") }
                        Divider()
                        Button { importing = true } label: { Label("File", systemImage: "doc") }
                        PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                            Label("Photos & Videos", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Attach")
                    .accessibilityIdentifier("composer.attach")

                    HStack(alignment: .bottom) {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .lineLimit(1...8)
                            .focused(focused)
                            .accessibilityIdentifier("composer.field")
                            .padding(.vertical, 11)
                            .padding(.leading, 16)
                            .onChange(of: text) { old, new in
                                // "/" on an empty composer opens the palette instead of Telegram's raw commands.
                                if old.isEmpty, new == "/" { text = ""; model.showCommands = true }
                                typingPing()
                            }
                        // Inside the glass field: filled, as Messages' send button (never glass on glass).
                        Button(action: send) {
                            Image(systemName: sending ? "ellipsis" : "arrow.up")
                                .font(.body.weight(.bold))
                                .frame(width: 22, height: 22)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .padding(5)
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("composer.send")
                    }
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
            }
        }
        .sheet(isPresented: Bindable(model).showCommands) {
            CommandPalette(topic: topic) { inserted in
                text = inserted
                focused.wrappedValue = true
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { addFile(url, securityScoped: true) }
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

    private var placeholder: String { topic == .main ? String(localized: "Message Hermes") : String(localized: "Message") }

    private var canSend: Bool {
        !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
    }

    private func fileChip(_ f: PendingFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileKind.symbol(for: f.url.lastPathComponent))
            VStack(alignment: .leading, spacing: 0) {
                Text(f.url.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                let size = ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
                Text(f.size > store.client.uploadLimit ? String(localized: "\(size) · via \(store.uploader.serviceName)") : size)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { files.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 220)
        .glassEffect(in: .rect(cornerRadius: 14))
    }

    private func addFile(_ url: URL, securityScoped: Bool) {
        // Copy out of the picker's sandbox: the upload may outlive the security scope.
        let scoped = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            files.append(PendingFile(url: dest, size: size))
        } catch {
            model.showToast("Couldn't attach \(url.lastPathComponent)")
        }
    }

    private func typingPing() {
        guard Date().timeIntervalSince(lastTyping) > 4, !text.isEmpty else { return }
        lastTyping = .now
        store.userIsTyping(in: topic)
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = files.map(\.url)
        text = ""
        files = []
        sending = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            defer {
                sending = false
                for u in urls { try? FileManager.default.removeItem(at: u) }
            }
            do {
                try await store.send(body, in: topic, files: urls)
            } catch {
                text = body
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

struct UploadRow: View {
    let upload: UploadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Uploading \(upload.name) to \(upload.service)").font(.caption.weight(.medium)).lineLimit(1)
            ProgressView(value: upload.fraction)
        }
        .padding(10)
        .glassEffect(in: .rect(cornerRadius: 14))
    }
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
