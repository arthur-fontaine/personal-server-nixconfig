import Foundation
import HermesCore
import Network

/// LFM3-Omni-2B on the device: downloaded once (Wi-Fi only, size shown), deletable.
/// Q4_0: the smallest quant, which llama.cpp repacks for Arm at load (docs.liquid.ai, "iOS & Android").
@MainActor
@Observable
final class VoiceModelStore: NSObject {
    static let shared = VoiceModelStore()

    nonisolated struct Asset: Sendable {
        let file: String
        let bytes: Int64
        var url: URL { URL(string: "https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/\(file)")! }
    }

    // Sizes from the repository listing (huggingface.co/api/models/LiquidAI/LFM3-Omni-2B-GGUF/tree/main).
    nonisolated static let model = Asset(file: "LFM3-Omni-2B-Q4_0.gguf", bytes: 1_050_000_000)
    nonisolated static let projector = Asset(file: "mmproj-LFM3-Omni-2B-Q4_0.gguf", bytes: 271_000_000)
    static var totalBytes: Int64 { model.bytes + projector.bytes }

    enum State: Equatable {
        case absent
        case downloading(Double)
        case waitingForWiFi
        case ready
        case failed(String)
    }

    private(set) var state: State = .absent
    private var tasks: [URLSessionDownloadTask] = []
    private var received: [String: Int64] = [:]
    private var monitor: NWPathMonitor?
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: (Bundle.main.bundleIdentifier ?? "hermes") + ".voicemodel")
        // 1.3 GB: never over cellular or a hotspot.
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    nonisolated static var directory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "VoiceModel", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Re-downloadable: keep it out of iCloud/iTunes backups.
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }

    nonisolated static func path(_ asset: Asset) -> URL { directory.appending(path: asset.file) }

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        let have = [Self.model, Self.projector].allSatisfy { FileManager.default.fileExists(atPath: Self.path($0).path) }
        if have { state = .ready } else if case .downloading = state {} else { state = .absent }
    }

    var onDiskBytes: Int64 {
        [Self.model, Self.projector].reduce(0) { sum, a in
            sum + Int64((try? Self.path(a).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func download() {
        guard state != .ready else { return }
        received = [:]
        state = .downloading(0)
        tasks = [Self.model, Self.projector].filter { !FileManager.default.fileExists(atPath: Self.path($0).path) }.map {
            let t = session.downloadTask(with: $0.url)
            t.taskDescription = $0.file
            t.countOfBytesClientExpectsToReceive = $0.bytes
            t.resume()
            return t
        }
        watchWiFi()
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
        monitor?.cancel()
        refresh()
    }

    func delete() {
        cancel()
        try? FileManager.default.removeItem(at: Self.directory)
        LFMEngineHolder.shared.unload()
        state = .absent
    }

    private func watchWiFi() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .downloading = self.state, path.isExpensive || path.status != .satisfied { self.state = .waitingForWiFi }
                else if self.state == .waitingForWiFi, !path.isExpensive, path.status == .satisfied { self.state = .downloading(self.progress) }
            }
        }
        m.start(queue: .main)
        monitor = m
    }

    private var progress: Double {
        Double(received.values.reduce(0, +)) / Double(Self.totalBytes)
    }
}

extension VoiceModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        let name = downloadTask.taskDescription ?? ""
        MainActor.assumeIsolated {
            received[name] = totalBytesWritten
            state = .downloading(progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file goes away when this returns: move it now, synchronously.
        guard let name = downloadTask.taskDescription else { return }
        let dest = VoiceModelStore.directory.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                state = .failed(error.localizedDescription)
            } else {
                refresh()
                if state == .ready { monitor?.cancel() }
            }
        }
    }
}
