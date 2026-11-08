import Foundation

/// The voice Hermes speaks with in calls, chosen in Settings. LFM3-Omni takes it in its TTS
/// system prompt; Apple's fallback picks an installed voice of the same gender.
public enum CallVoice: String, Sendable, CaseIterable, Identifiable {
    case female, male

    public var id: String { rawValue }

    public static let defaultsKey = "callVoice"
    public static let `default`: CallVoice = .female

    public static func current(_ defaults: UserDefaults = .standard) -> CallVoice {
        defaults.string(forKey: defaultsKey).flatMap(CallVoice.init(rawValue:)) ?? .default
    }

    /// One of Apple's installed voices for `language` with this gender, best quality first; nil
    /// when the language has none of that gender (the caller then takes the language's default).
    public func pick(from voices: [Candidate], language: String) -> String? {
        let wanted = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = String(wanted.prefix(2))
        let fitting = voices.filter { $0.isMale == (self == .male) && $0.language.lowercased().hasPrefix(base) }
        return fitting.max { a, b in
            // Exact region first (fr-FR before fr-CA), then quality.
            (a.language.lowercased() == wanted ? 1 : 0, a.quality) < (b.language.lowercased() == wanted ? 1 : 0, b.quality)
        }?.identifier
    }

    /// What `pick` needs of an `AVSpeechSynthesisVoice`, so the choice is testable without one.
    public struct Candidate: Sendable, Equatable {
        public var identifier: String
        public var language: String
        public var isMale: Bool
        public var quality: Int
        public init(identifier: String, language: String, isMale: Bool, quality: Int) {
            self.identifier = identifier
            self.language = language
            self.isMale = isMale
            self.quality = quality
        }
    }
}

/// LFM3-Omni's system prompts, as its model card words them
/// (huggingface.co/LiquidAI/LFM3-Omni-2B: "Perform ASR in <language>.", "Perform TTS in
/// <language> using a <gender> voice."), in its ChatML template.
public enum LFMPrompt {
    /// The language's English name, as the prompts want it.
    public static func languageName(_ id: String) -> String {
        let code = String(id.prefix(2))
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// TTS names English's variant ("American English" or "British English").
    public static func speechLanguage(_ id: String) -> String {
        if id.hasPrefix("en") { return id.contains("GB") ? "British English" : "American English" }
        return languageName(id)
    }

    public static func asr(language: String, marker: String) -> String {
        "<|im_start|>system\nPerform ASR in \(languageName(language)).<|im_end|>\n<|im_start|>user\n\(marker)<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    /// The "tts" turn of the chat template, ending with <|audio_start|> (llama.cpp's audio
    /// generation helper checks it).
    public static func tts(_ text: String, language: String, voice: CallVoice) -> String {
        "<|startoftext|><|im_start|>system\nPerform TTS in \(speechLanguage(language)) using a \(voice.rawValue) voice.<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n<think></think><|audio_start|>"
    }
}
