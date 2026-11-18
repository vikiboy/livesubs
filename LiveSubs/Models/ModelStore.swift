import Foundation
import WhisperKit

/// Whisper models offered in the app (CoreML builds from huggingface.co/argmaxinc/whisperkit-coreml,
/// MIT-licensed OpenAI Whisper weights). Downloaded once, then used fully offline.
struct WhisperModel: Identifiable, Hashable, Codable {
    let variant: String
    let displayName: String
    let approxMB: Int
    let summary: String
    /// Whisper's built-in "translate to English" head. OpenAI's large-v3 *turbo*
    /// was trained without translation data, so it only transcribes.
    let supportsTranslate: Bool

    var id: String { variant }

    static let catalog: [WhisperModel] = [
        .init(variant: "openai_whisper-tiny", displayName: "Tiny", approxMB: 75,
              summary: "Fastest, lowest accuracy. Good for older iPhones or quick tests.", supportsTranslate: true),
        .init(variant: "openai_whisper-base", displayName: "Base", approxMB: 145,
              summary: "Fast and light. Fine for clear speech.", supportsTranslate: true),
        .init(variant: "openai_whisper-small_216MB", displayName: "Small (recommended)", approxMB: 216,
              summary: "Best balance of speed, accuracy and battery on recent iPhones.", supportsTranslate: true),
        .init(variant: "openai_whisper-small", displayName: "Small (full precision)", approxMB: 480,
              summary: "Slightly better than compressed Small, double the size.", supportsTranslate: true),
        .init(variant: "openai_whisper-large-v3-v20240930_626MB", displayName: "Large v3 Turbo", approxMB: 626,
              summary: "Most accurate recognition. Translates via Apple language packs (no built-in translation). iPhone 15 Pro or newer.",
              supportsTranslate: false),
        .init(variant: "openai_whisper-large-v3_947MB", displayName: "Large v3", approxMB: 947,
              summary: "Best built-in translation, but slow — higher subtitle delay and battery use. iPhone 16 Pro or newer.",
              supportsTranslate: true),
    ]

    static let recommended = catalog[2]

    static func find(_ variant: String) -> WhisperModel? { catalog.first { $0.variant == variant } }
}

enum ModelStore {
    /// Application Support/Models — excluded from iCloud backup.
    static let baseURL: URL = {
        // LIVESUBS_MODELS_DIR is only used by the macOS test harness (Tests/Harness).
        let url = ProcessInfo.processInfo.environment["LIVESUBS_MODELS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
        return url
    }()

    private static func readyMarker(_ m: WhisperModel) -> URL {
        baseURL.appendingPathComponent(".ready-\(m.variant)")
    }

    /// Folder of a fully downloaded *and prepared* model, else nil.
    static func localFolder(for model: WhisperModel) -> URL? {
        guard let path = try? String(contentsOf: readyMarker(model), encoding: .utf8) else { return nil }
        // Stored relative to baseURL so it survives container path changes.
        let url = baseURL.appendingPathComponent(path, isDirectory: true)
        let encoder = url.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) ? url : nil
    }

    static func markReady(_ model: WhisperModel, folder: URL) {
        let rel = folder.path.replacingOccurrences(of: baseURL.path + "/", with: "")
        try? rel.write(to: readyMarker(model), atomically: true, encoding: .utf8)
    }

    static func delete(_ model: WhisperModel) throws {
        if let folder = localFolder(for: model) { try FileManager.default.removeItem(at: folder) }
        try? FileManager.default.removeItem(at: readyMarker(model))
    }

    static func sizeOnDisk(_ model: WhisperModel) -> Int64 {
        guard let folder = localFolder(for: model),
              let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

extension ModelStore {
    /// One hardware plan for every load. iOS keeps a separately optimized copy of a model
    /// per plan, so the download step, the warm-up and both engines must all use this one.
    static var computeOptions: ModelComputeOptions {
        ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
    }

    /// The build whose optimized copy of `model` is known to exist.
    static func warmedBuild(_ m: WhisperModel) -> String? { UserDefaults.standard.string(forKey: "warmed-" + m.variant) }
    static func setWarmed(_ m: WhisperModel) { UserDefaults.standard.set(currentBuild, forKey: "warmed-" + m.variant) }
    static var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
}

/// After an install, iOS discards its optimized copy of the models. LiveSubs re-creates it
/// in the background as soon as it opens; anything that loads a model waits for this
/// instead of doing the same slow work twice.
@MainActor
enum ModelWarmup {
    private(set) static var running: Task<Void, Never>?
    static func wait() async { await running?.value }

    static func start(_ m: WhisperModel, manager: ModelManager) {
        guard running == nil, ModelStore.localFolder(for: m) != nil, ModelStore.warmedBuild(m) != ModelStore.currentBuild else { return }
        manager.setPhase(m, .preparing)
        running = Task {
            if let folder = ModelStore.localFolder(for: m),
               let kit = try? await WhisperKit(WhisperKitConfig(
                   model: m.variant, downloadBase: ModelStore.baseURL, modelFolder: folder.path,
                   tokenizerFolder: ModelStore.baseURL, computeOptions: ModelStore.computeOptions,
                   verbose: false, logLevel: .error, prewarm: true, load: true, download: false)) {
                await kit.unloadModels()
                ModelStore.setWarmed(m)
            }
            manager.setPhase(m, .ready)
            running = nil
        }
    }
}

/// Download / prepare / delete state for the Models screen.
@MainActor
final class ModelManager: ObservableObject {
    enum Phase: Equatable {
        case notDownloaded
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var phases: [String: Phase] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init() { refresh() }

    func refresh() {
        for m in WhisperModel.catalog where tasks[m.variant] == nil {
            phases[m.variant] = ModelStore.localFolder(for: m) != nil ? .ready : .notDownloaded
        }
    }

    func phase(_ m: WhisperModel) -> Phase { phases[m.variant] ?? .notDownloaded }
    /// Downloaded and usable (warming up in the background still counts: loads wait for it).
    func isReady(_ m: WhisperModel) -> Bool { ModelStore.localFolder(for: m) != nil && tasks[m.variant] == nil }
    func setPhase(_ m: WhisperModel, _ p: Phase) { phases[m.variant] = p }

    func download(_ m: WhisperModel) {
        guard tasks[m.variant] == nil else { return }
        phases[m.variant] = .downloading(0)
        tasks[m.variant] = Task { [weak self] in
            do {
                let folder = try await WhisperKit.download(variant: m.variant, downloadBase: ModelStore.baseURL) { progress in
                    let f = progress.fractionCompleted
                    Task { @MainActor in self?.phases[m.variant] = .downloading(f) }
                }
                await MainActor.run { self?.phases[m.variant] = .preparing }
                // First load compiles/specialises the CoreML models for this device's
                // Neural Engine and caches the tokenizer, so later loads work offline.
                let kit = try await WhisperKit(WhisperKitConfig(
                    model: m.variant, downloadBase: ModelStore.baseURL, modelFolder: folder.path,
                    tokenizerFolder: ModelStore.baseURL, computeOptions: ModelStore.computeOptions,
                    verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
                await kit.unloadModels()
                ModelStore.markReady(m, folder: folder)
                await MainActor.run { ModelStore.setWarmed(m) }
                await MainActor.run { self?.phases[m.variant] = .ready }
            } catch is CancellationError {
                await MainActor.run { self?.phases[m.variant] = .notDownloaded }
            } catch {
                await MainActor.run { self?.phases[m.variant] = .failed(error.localizedDescription) }
            }
            await MainActor.run { self?.tasks[m.variant] = nil }
        }
    }

    #if DEBUG
    /// Design-review only: shows a download in progress without touching the network.
    func showDemoDownload(_ m: WhisperModel) { phases[m.variant] = .downloading(0.42) }
    #endif

    func cancel(_ m: WhisperModel) {
        tasks[m.variant]?.cancel()
    }

    func delete(_ m: WhisperModel) {
        try? ModelStore.delete(m)
        phases[m.variant] = .notDownloaded
    }
}
