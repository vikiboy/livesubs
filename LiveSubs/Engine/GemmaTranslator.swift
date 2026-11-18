import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Google's TranslateGemma 4B (4-bit, MLX) translating Japanese/Korean/… straight into
/// natural English subtitles, on this device's GPU. Chosen over Apple Translation + an
/// Apple Intelligence rewrite after a side-by-side test: as accurate, more natural, never
/// flipped a meaning. Weights: mlx-community/translategemma-4b-it-4bit (Gemma licence).
actor GemmaTranslator {
    static let repo = "mlx-community/translategemma-4b-it-4bit"
    static let files = ["config.json", "generation_config.json", "model.safetensors.index.json",
                        "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json",
                        "tokenizer.model", "added_tokens.json", "model.safetensors"]
    static let approxMB = 2220

    /// Where the weights live: next to the speech models, or $LIVESUBS_GEMMA_DIR for tests.
    static var folder: URL {
        if let dir = ProcessInfo.processInfo.environment["LIVESUBS_GEMMA_DIR"] { return URL(fileURLWithPath: dir) }
        return ModelStore.baseURL.appendingPathComponent("translategemma-4b-it-4bit", isDirectory: true)
    }
    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".complete").path)
            || ProcessInfo.processInfo.environment["LIVESUBS_GEMMA_DIR"] != nil
    }

    static let shared = GemmaTranslator()

    /// iOS doesn't allow GPU work from the background: the browser clears this when the
    /// app leaves the screen, and the engine waits until it's set again.
    nonisolated(unsafe) static var allowed = true

    private var container: ModelContainer?
    /// Measured on this device, for the practice report.
    private(set) var loadSeconds: Double?
    private(set) var linesTranslated = 0
    private(set) var secondsTranslating: Double = 0
    private var loading: Task<ModelContainer, Error>?

    /// Loads once; later calls reuse it. Keeps MLX's GPU cache small so speech models
    /// and the web view keep their memory (an 8 GB iPhone gives one app about 4.5–6 GB).
    func load() async throws -> ModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task { () throws -> ModelContainer in
            MLX.Memory.cacheLimit = 64 * 1024 * 1024
            return try await loadModelContainer(from: Self.folder, using: HFTokenizerLoader())
        }
        loading = task
        let began = Date()
        do {
            let c = try await task.value
            container = c; loading = nil
            loadSeconds = Date().timeIntervalSince(began)
            return c
        } catch { loading = nil; throw error }
    }

    func unload() { container = nil; loading = nil; MLX.Memory.clearCache() }

    var isLoaded: Bool { container != nil }

    /// "loaded in 21 s, 1.4 s per line" (nil before first use).
    func speedSummary() -> String? {
        guard linesTranslated > 0 else { return nil }
        var parts: [String] = []
        if let l = loadSeconds, l > 1 { parts.append(String(format: "loaded in %.0f s", l)) }
        parts.append(String(format: "%.1f s per line", secondsTranslating / Double(linesTranslated)))
        return parts.joined(separator: ", ")
    }

    /// One subtitle line, source language code → English.
    func translate(_ text: String, from language: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let container = try await load()
        let began = Date()
        defer { linesTranslated += 1; secondsTranslating += Date().timeIntervalSince(began) }
        let prompt = Self.prompt(trimmed, from: language)
        let output: String = try await container.perform { context in
            let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let input = LMInput(tokens: MLXArray(tokens))
            let parameters = GenerateParameters(maxTokens: 160, temperature: 0)
            var ids: [Int] = []
            let endIds = Set(["<end_of_turn>", "<eos>"].compactMap { context.tokenizer.convertTokenToId($0) })
            for await event in try generateTokens(input: input, parameters: parameters, context: context) {
                if case .token(let id) = event {
                    if endIds.contains(id) { break }
                    ids.append(id)
                }
            }
            return context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: true)
        }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.isEmpty ? text : line
    }

    /// TranslateGemma's own chat template (chat_template.jinja), filled in directly.
    static func prompt(_ text: String, from code: String) -> String {
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        return "<bos><start_of_turn>user\nYou are a professional \(name) (\(code)) to English (en) translator. "
            + "Your goal is to accurately convey the meaning and nuances of the original \(name) text while adhering "
            + "to English grammar, vocabulary, and cultural sensitivities.\nProduce only the English translation, "
            + "without any additional explanations or commentary. Please translate the following \(name) text into "
            + "English:\n\n\n\(text)<end_of_turn>\n<start_of_turn>model\n"
    }
}

/// Hugging Face's tokenizer (swift-transformers) adapted to MLX's protocol.
struct HFTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages)
    }
}

struct HFTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        HFTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// One-time download of TranslateGemma's weights (2.2 GB) into the app's storage.
@MainActor
final class GemmaDownloader: ObservableObject {
    static let shared = GemmaDownloader()
    @Published private(set) var phase: ModelManager.Phase = GemmaTranslator.isDownloaded ? .ready : .notDownloaded
    private var task: Task<Void, Never>?

    func download() {
        guard task == nil, phase != .ready else { return }
        phase = .downloading(0)
        task = Task {
            let folder = GemmaTranslator.folder
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var excluded = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
                let session = URLSession(configuration: .ephemeral)
                let files = GemmaTranslator.files
                for (i, name) in files.enumerated() {
                    let dest = folder.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: dest.path) { continue }
                    let url = URL(string: "https://huggingface.co/\(GemmaTranslator.repo)/resolve/main/\(name)")!
                    let base = Double(i) / Double(files.count)
                    let (tmp, response) = try await session.download(from: url, delegate: Progress(onProgress: { f in
                        Task { @MainActor in
                            // The weights file is nearly all of the size; weight progress by it.
                            self.phase = .downloading(name == "model.safetensors" ? 0.02 + f * 0.98 : min(0.02, base))
                        }
                    }))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                }
                FileManager.default.createFile(atPath: folder.appendingPathComponent(".complete").path, contents: Data())
                phase = .ready
            } catch is CancellationError {
                phase = .notDownloaded
            } catch {
                phase = .failed("Download failed: \(error.localizedDescription)")
            }
            task = nil
        }
    }

    func delete() {
        task?.cancel(); task = nil
        try? FileManager.default.removeItem(at: GemmaTranslator.folder)
        phase = .notDownloaded
    }

    /// Reports a download's progress by observing the task's own Progress object.
    private final class Progress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in onProgress(p.fractionCompleted) }
        }
    }
}
