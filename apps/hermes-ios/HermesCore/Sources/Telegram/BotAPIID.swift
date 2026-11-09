import Foundation

/// The protocol's message ids are the Bot API's (the server's own numbering, what `app_topic` sees),
/// while TDLib numbers a server message `server id << 20`, keeping the low bits for messages not
/// yet on the server (https://core.telegram.org/tdlib/docs/classtd_1_1td__api_1_1message.html,
/// `id`). Every id crossing between the App topic's JSON and TDLib goes through here. Topic ids need
/// no conversion: TDLib's `forum_topic_id` is the Bot API's `message_thread_id`.
public enum BotAPIID {
    static let shift: MessageID = 20

    /// The TDLib id of the message the protocol calls `id`.
    public static func tdlib(_ id: MessageID) -> MessageID { id << shift }

    /// The protocol's id of a TDLib message; nil for a message not on the server yet.
    public static func botAPI(_ tdlib: MessageID) -> MessageID? {
        guard tdlib > 0, tdlib & ((1 << shift) - 1) == 0 else { return nil }
        return tdlib >> shift
    }
}
