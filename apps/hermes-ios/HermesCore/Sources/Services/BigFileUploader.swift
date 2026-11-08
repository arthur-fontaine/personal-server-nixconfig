import Foundation

/// Uploads a file Telegram won't take (over the account's 2/4 GB cap) and returns its link,
/// which the message then carries as `[fichier: <url>]`.
public protocol BigFileUploader: Sendable {
    var serviceName: String { get }
    func upload(file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

public enum BigFileUploaders {
    /// SwissTransfer when an Infomaniak token is configured, else Gofile (no account needed).
    /// See DECISIONS.md: SwissTransfer's anonymous API needs App Attest tokens of Infomaniak's own app.
    public static func preferred(config: AppConfig, session: URLSession = .shared) -> any BigFileUploader {
        if let token = config.swissTransferToken { return SwissTransferUploader(token: token, session: session) }
        return GofileUploader(session: session)
    }
}

public enum UploadError: LocalizedError {
    case service(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .service(let s): L("Upload failed: \(s)")
        case .badResponse: L("Upload failed: unexpected answer from the service.")
        }
    }
}

// MARK: - Gofile

/// https://gofile.io/api — `POST https://upload.gofile.io/uploadfile`, multipart, no size cap;
/// without a token a guest account is created, whose token we keep to reuse one account.
public struct GofileUploader: BigFileUploader {
    public let serviceName = "Gofile"
    let session: URLSession
    let endpoint = URL(string: "https://upload.gofile.io/uploadfile")!
    static let tokenKey = "gofile.guestToken"

    public init(session: URLSession = .shared) { self.session = session }

    public func upload(file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let boundary = "hermes-\(UUID().uuidString)"
        // Multipart bodies are streamed from a temporary file: a 10 GB video never sits in memory.
        let body = try MultipartFile.write(file: file, field: "file", boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = UserDefaults.standard.string(forKey: Self.tokenKey) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await session.upload(for: request, fromFile: body, delegate: ProgressDelegate(progress))
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> URL {
        struct Envelope: Decodable {
            struct Payload: Decodable { let downloadPage: String?; let guestToken: String? }
            let status: String
            let data: Payload?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        guard env.status == "ok" else { throw UploadError.service(env.status) }
        if let token = env.data?.guestToken { UserDefaults.standard.set(token, forKey: tokenKey) }
        guard let page = env.data?.downloadPage, let url = URL(string: page) else { throw UploadError.badResponse }
        return url
    }
}

// MARK: - SwissTransfer (v2, with an Infomaniak token)

/// The flow of Infomaniak's own client (github.com/Infomaniak/multiplatform-SwissTransfer,
/// STNetwork/requests/v2/UploadRequest.kt): create a transfer, upload each 50 MB chunk to a
/// presigned URL, finalize the file with the chunks' ETags, then the transfer, which returns the link.
public struct SwissTransferUploader: BigFileUploader {
    public let serviceName = "SwissTransfer"
    let token: String
    let session: URLSession
    // ApiEnvironment.Prod.baseUrlV2 + ApiRoutes.apiBaseUrlV2 in the same repository.
    let api = URL(string: "https://swisstransfer.infomaniak.com/api/1/")!
    let chunkSize: Int64 = 50 * 1024 * 1024

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    public func upload(file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let create: [String: Any] = [
            "language": "en", "expires_in_days": 30, "max_download": 250, "recipients": [],
            "files": [["path": file.lastPathComponent, "size": size, "mime_type": ""]],
        ]
        let transfer = try await call("POST", "transfers", body: create)
        guard let data = transfer["data"] as? [String: Any], let transferID = data["id"] as? String,
              let files = data["files"] as? [[String: Any]], let fileID = files.first?["id"] as? String else {
            throw UploadError.badResponse
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var etags: [[String: Any]] = []
        var sent: Int64 = 0
        var index = 1 // chunk indexes start at 1 (ChunkEtag.kt)
        while sent < size {
            let chunk = try handle.read(upToCount: Int(chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            let presigned = try await call("POST", "transfers/\(transferID)/files/\(fileID)/chunks/\(index)")
            guard let urlString = (presigned["data"] as? [String: Any])?["url"] as? String, let url = URL(string: urlString) else {
                throw UploadError.badResponse
            }
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            let (_, response) = try await session.upload(for: put, from: chunk)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let etag = http.value(forHTTPHeaderField: "Etag") else { throw UploadError.service("chunk \(index)") }
            etags.append(["etag": etag, "chunk_index": index])
            sent += Int64(chunk.count)
            progress(sent)
            index += 1
        }
        _ = try await call("PATCH", "transfers/\(transferID)/files/\(fileID)", body: ["etags": etags])
        let done = try await call("PATCH", "transfers/\(transferID)", body: ["status": "completed"])
        guard let link = ((done["data"] as? [String: Any])?["link"] as? [String: Any])?["id"] as? String,
              let url = URL(string: "https://swisstransfer.infomaniak.com/dl/\(link)") else { throw UploadError.badResponse }
        return url
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: api.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadError.service(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Helpers

enum MultipartFile {
    static func write(file: URL, field: String, boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        writer.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { writer.write(chunk) }
        writer.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}

final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}
