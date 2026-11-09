import Foundation
import HermesCore

/// Loads the LFM engine once per process, off the main thread, and keeps it while calls come.
nonisolated final class LFMEngineHolder: @unchecked Sendable {
    static let shared = LFMEngineHolder()
    private let lock = NSLock()
    private var engine: (any VoiceEngine)?
    private(set) var lastError: String?

    /// The on-device model if downloaded and loadable, else nil (the caller falls back to Apple's).
    func load() async -> (any VoiceEngine)? {
        if let engine = current() { return engine }
        #if canImport(llama)
        let model = await VoiceModelStore.path(VoiceModelStore.model).path
        let proj = await VoiceModelStore.path(VoiceModelStore.projector).path
        guard FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: proj) else { return nil }
        do {
            let e = try await Task.detached(priority: .userInitiated) { try LFMVoiceEngine(modelPath: model, projectorPath: proj) }.value
            lock.withLock { engine = e }
            return e
        } catch {
            lastError = error.localizedDescription
            CallLog.shared.log("lfm: load failed: \(error.localizedDescription)")
            return nil
        }
        #else
        lastError = String(localized: "This build has no llama.cpp (the simulator).")
        return nil
        #endif
    }

    private func current() -> (any VoiceEngine)? { lock.withLock { engine } }

    func unload() { lock.withLock { engine = nil } }
}

#if canImport(llama)
import llama

/// LFM3-Omni-2B through llama.cpp: ASR with `mtmd` audio input, speech with the LFM3 audio
/// generation helper (codec decoder + ISTFT, 24 kHz), both from llama.cpp's C API
/// (tools/mtmd/mtmd.h and mtmd-helper.h at the pinned build). One model serves both; calls
/// into it are serialized by an actor-like lock since a llama context isn't re-entrant.
nonisolated final class LFMVoiceEngine: VoiceEngine, @unchecked Sendable {
    let name = String(localized: "LFM3-Omni-2B (on device)")
    let outputSampleRate: Double = 24_000

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let mctx: OpaquePointer
    private let vocab: OpaquePointer
    private let gen: OpaquePointer
    private let queue = DispatchQueue(label: "hermes.lfm", qos: .userInitiated)
    private let nBatch: Int32 = 512
    /// What the audio projector takes (`mtmd_get_audio_sample_rate`); the call records 16 kHz.
    private let inputRate: Int32

    init(modelPath: String, projectorPath: String) throws {
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(modelPath, mp) else { throw VoiceEngineError.failed(String(localized: "The voice model didn't load.")) }
        var cp = llama_context_default_params()
        cp.n_ctx = 4096
        cp.n_batch = UInt32(nBatch)
        cp.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        cp.n_threads_batch = cp.n_threads
        // The speech helper reads the backbone's hidden state each frame.
        cp.embeddings = true
        guard let ctx = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw VoiceEngineError.failed(String(localized: "Not enough memory for the voice model."))
        }
        var mtp = mtmd_context_params_default()
        mtp.use_gpu = true
        guard let mctx = mtmd_init_from_file(projectorPath, model, mtp) else {
            llama_free(ctx); llama_model_free(model)
            throw VoiceEngineError.failed(String(localized: "The voice projector didn't load."))
        }
        guard mtmd_support_audio(mctx), mtmd_gen_audio_get_info(mctx).type == MTMD_GEN_AUDIO_TYPE_LFM3A,
              let gen = mtmd_helper_gen_audio_init(ctx, mctx) else {
            mtmd_free(mctx); llama_free(ctx); llama_model_free(model)
            throw VoiceEngineError.failed(String(localized: "This llama.cpp build can't run LFM3 speech."))
        }
        inputRate = mtmd_get_audio_sample_rate(mctx)
        CallLog.shared.log("lfm: loaded, audio input \(inputRate) Hz, \(cp.n_threads) threads")
        self.model = model
        self.ctx = ctx
        self.mctx = mctx
        self.vocab = llama_model_get_vocab(model)
        self.gen = gen
    }

    deinit {
        mtmd_helper_gen_audio_free(gen)
        mtmd_free(mctx)
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: ASR

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try self.transcribeSync(samples, language: language) }) }
        }
    }

    private func transcribeSync(_ samples: [Float], language: String) throws -> String {
        llama_memory_clear(llama_get_memory(ctx), true)
        let marker = String(cString: mtmd_default_marker())
        let prompt = LFMPrompt.asr(language: language, marker: marker)
        // The projector's own rate: feeding 16 kHz to a model expecting another one reads as
        // noise (it answered nothing).
        let samples = inputRate > 0 && inputRate != 16_000 ? Resample.linear(samples, from: 16_000, to: Double(inputRate)) : samples
        guard let bitmap = samples.withUnsafeBufferPointer({ mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }) else {
            throw VoiceEngineError.failed(String(localized: "The audio couldn't be prepared."))
        }
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        let rc: Int32 = prompt.withCString { cstr in
            var text = mtmd_input_text(text: cstr, text_len: strlen(cstr), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mctx, chunks, &text, $0.baseAddress, 1) }
        }
        guard rc == 0 else { throw VoiceEngineError.failed(String(localized: "The voice model couldn't read the audio (\(rc)).")) }
        var nPast: llama_pos = 0
        guard mtmd_helper_eval_chunks(mctx, ctx, chunks, 0, 0, nBatch, true, &nPast) == 0 else {
            throw VoiceEngineError.failed(String(localized: "Listening failed."))
        }
        // Greedy decoding for text (model card).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var bytes: [UInt8] = []
        for _ in 0..<256 {
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            var batch = llama_batch_get_one(&token, 1)
            batch.n_tokens = 1
            if llama_decode(ctx, batch) != 0 { break }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        return n <= 0 ? [] : buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    // MARK: TTS

    func synthesize(_ text: String, language: String, voice: CallVoice) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let cancelled = CancelFlag()
        continuation.onTermination = { _ in cancelled.set() }
        let prompt = LFMPrompt.tts(text, language: language, voice: voice)
        queue.async {
            do {
                try self.synthesizeSync(prompt: prompt, cancelled: cancelled) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    private func synthesizeSync(prompt: String, cancelled: CancelFlag, emit: ([Float]) -> Void) throws {
        llama_memory_clear(llama_get_memory(ctx), true)
        mtmd_helper_gen_audio_reset(gen)
        try prompt.withCString { cstr in
            var inp = mtmd_helper_gen_audio_inp_default()
            inp.stream = true
            inp.seq_id = 0
            inp.prompt = cstr
            inp.prompt_len = strlen(cstr)
            inp.out_type = MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM
            guard mtmd_helper_gen_audio_set_input(gen, &inp) == 0 else { throw VoiceEngineError.failed(String(localized: "Speaking failed.")) }
        }
        while true {
            let left = mtmd_helper_gen_audio_step_prompt(gen, nBatch)
            if left < 0 { throw VoiceEngineError.failed(String(localized: "Speaking failed.")) }
            if left == 0 { break }
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var h = llama_get_embeddings_ith(ctx, -1)
        // ~12.5 frames per second of speech: 40 s at most for one sentence.
        for _ in 0..<500 {
            if cancelled.isSet { return }
            var token: llama_token = -1 // LLAMA_TOKEN_NULL: audio frames come from the hidden state
            if mtmd_helper_gen_audio_next_is_text(gen) { token = llama_sampler_sample(sampler, ctx, -1) }
            var next: UnsafePointer<Float>?
            var stop = false
            guard mtmd_helper_gen_audio_step_gen(gen, token, h, &next, &stop) == 0 else { throw VoiceEngineError.failed(String(localized: "Speaking failed.")) }
            drain(emit)
            if stop || next == nil { break }
            h = UnsafeMutablePointer(mutating: next)
        }
        mtmd_helper_gen_audio_flush(gen)
        drain(emit)
    }

    private func drain(_ emit: ([Float]) -> Void) {
        var rate: Int32 = 0
        var data: UnsafePointer<CChar>?
        var len = 0
        guard mtmd_helper_gen_audio_get_output(gen, &rate, &data, &len, nil) == 0, let data, len > 0 else { return }
        // OUTTYPE_PCM is float32 (mtmd-helper-gen.cpp: out_data_len = n * sizeof(float)).
        let n = len / MemoryLayout<Float>.size
        data.withMemoryRebound(to: Float.self, capacity: n) { emit(Array(UnsafeBufferPointer(start: $0, count: n))) }
    }
}

nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
