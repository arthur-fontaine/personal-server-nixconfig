import ActivityKit
import Foundation

/// The Live Activity shown while Hermes works or waits for an answer. The content state mirrors
/// what the backend pushes with a paid team (protocol §4: `status`, `task`, `chat`, `question`).
public struct HermesActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var status: AgentStatus
        public var task: String?
        public var chat: TopicID
        public var chatName: String?
        public var since: Date
        public var question: ActivityQuestion?
        public var petMood: PetMood

        public init(status: AgentStatus, task: String?, chat: TopicID, chatName: String?, since: Date,
                    question: ActivityQuestion?, petMood: PetMood) {
            self.status = status
            self.task = task
            self.chat = chat
            self.chatName = chatName
            self.since = since
            self.question = question
            self.petMood = petMood
        }

        enum CodingKeys: String, CodingKey { case status, task, chat, chatName, since, question, petMood }

        /// A backend push (protocol §4) carries only `status`, `task`, `chat`, `question`: the
        /// rest gets defaults, the pet's mood from the status.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = (try? c.decode(AgentStatus.self, forKey: .status)) ?? .idle
            task = try? c.decodeIfPresent(String.self, forKey: .task)
            chat = (try? c.decodeIfPresent(TopicID.self, forKey: .chat)) ?? .main
            chatName = try? c.decodeIfPresent(String.self, forKey: .chatName)
            since = (try? c.decodeIfPresent(Date.self, forKey: .since)) ?? .now
            question = try? c.decodeIfPresent(ActivityQuestion.self, forKey: .question)
            petMood = (try? c.decodeIfPresent(PetMood.self, forKey: .petMood))
                ?? PetMood(agent: status, reported: nil, until: nil)
        }
    }

    public var petName: String
    /// File name of the spritesheet in the App Group, for the pet's frame.
    public var spritesheetFile: String?

    public init(petName: String, spritesheetFile: String?) {
        self.petName = petName
        self.spritesheetFile = spritesheetFile
    }
}

/// A question as the Live Activity needs it: short, and buttons it can press through App Intents.
public struct ActivityQuestion: Codable, Hashable, Sendable {
    public struct Option: Codable, Hashable, Sendable {
        public var id: String
        public var label: String
        public var destructive: Bool
        public init(id: String, label: String, destructive: Bool) {
            self.id = id
            self.label = label
            self.destructive = destructive
        }
    }

    public var id: String
    public var kind: PendingQuestion.Kind
    public var title: String
    public var detail: String?
    public var options: [Option]

    public init(id: String, kind: PendingQuestion.Kind, title: String, detail: String?, options: [Option]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.options = options
    }

    public init(_ q: PendingQuestion) {
        id = q.id
        kind = q.kind
        title = q.summary ?? q.text
        detail = q.kind == .approval ? q.command : nil
        // A Live Activity fits about four short buttons; a clarify's "Other…" needs the keyboard.
        options = q.options.filter { $0.id != "other" }.prefix(4).map {
            Option(id: $0.id, label: $0.label, destructive: $0.isDestructive)
        }
    }
}

