import Foundation
import FoundationModels

enum GenerationEvent: Sendable {
    case delta(String)
    case done(String)
    case heartbeat
}

actor Engine {
    private var occupied = false
    private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []
    private var completed = 0
    private var cancelled = 0
    private var failed = 0
    private var last: Measurement?
    private var activeModel: String?
    private var activeLanguage: String?
    private var healthSubscribers: [UUID: AsyncStream<Health>.Continuation] = [:]
    private var healthHeartbeat: Task<Void, Never>?

    struct Measurement: Encodable, Sendable {
        let model: String
        let promptVersion: String
        let firstContentMilliseconds: Int?
        let totalMilliseconds: Int
        let outputCharacters: Int
        let outcome: String
    }

    struct Health: Encodable, Sendable {
        let service: String
        let apiVersion: Int
        let status: String
        let modelAvailability: String
        let active: Bool
        let activeModel: String?
        let activeLanguage: String?
        let queued: Int
        let completed: Int
        let cancelled: Int
        let failed: Int
        let last: Measurement?
    }

    func health() -> Health {
        let available = SystemLanguageModel.default.isAvailable
        return .init(service: "vscode-apple-intelligence-api", apiVersion: 1,
                     status: available ? "ok" : "unavailable",
                     modelAvailability: String(describing: SystemLanguageModel.default.availability),
                     active: occupied, activeModel: activeModel, activeLanguage: activeLanguage,
                     queued: waiting.count, completed: completed,
                     cancelled: cancelled, failed: failed, last: last)
    }

    func subscribeHealth() -> (UUID, AsyncStream<Health>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Health>.makeStream()
        healthSubscribers[id] = continuation
        continuation.yield(health())
        continuation.onTermination = { @Sendable _ in
            Task { await self.unsubscribeHealth(id) }
        }
        if healthHeartbeat == nil {
            healthHeartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { break }
                    if !Task.isCancelled { self.publishHealth() }
                }
            }
        }
        return (id, stream)
    }

    func unsubscribeHealth(_ id: UUID) {
        healthSubscribers.removeValue(forKey: id)?.finish()
        if healthSubscribers.isEmpty {
            healthHeartbeat?.cancel()
            healthHeartbeat = nil
        }
    }

    private func publishHealth() {
        let snapshot = health()
        for continuation in healthSubscribers.values { continuation.yield(snapshot) }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if occupied { waiting.append((id, continuation)); publishHealth() }
                else { occupied = true; continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: index).1.resume(throwing: CancellationError())
            publishHealth()
        }
    }

    private func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().1.resume() }
    }

    func generate(_ input: PreparedRequest, emit: @Sendable (GenerationEvent) -> Void) async throws {
        let started = ContinuousClock.now
        var first: Int?
        var count = 0
        try await acquire()
        activeModel = input.model
        activeLanguage = input.language
        publishHealth()
        defer { activeModel = nil; activeLanguage = nil; release(); publishHealth() }
        do {
            try Task.checkCancellation()
            guard SystemLanguageModel.default.isAvailable else {
                throw APIError("model_unavailable", "Apple Intelligenceのモデルが利用できません。", status: .serviceUnavailable)
            }
            let session = LanguageModelSession(instructions: input.instructions)
            let sampling: GenerationOptions.SamplingMode? = input.temperature == 0 ? .greedy : input.topP.map { .random(probabilityThreshold: $0) }
            let options = GenerationOptions(sampling: sampling,
                                            temperature: input.temperature == 0 ? nil : input.temperature,
                                            maximumResponseTokens: input.maxTokens)
            var full = ""
            var emitted = ""
            var stopFound = false
            if input.task == .nes {
                // 構造化応答が完了するまで本文を公開しない。途中の編集は提案にしない。
                let editSchema = DynamicGenerationSchema(name: "TextEdit", properties: [
                    .init(name: "find", description: "Exact existing identifier or short phrase in TARGET to replace. Choose a unique match, without cursor tags.", schema: .init(type: String.self)),
                    .init(name: "replace", description: "New text for only the matched identifier or phrase. Preserve language syntax, including $ for shell variables.", schema: .init(type: String.self))
                ])
                let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "NextEdits", properties: [
                    .init(name: "edits", description: "Minimal edits continuing the most recent change. Empty if no change is needed.", schema: .init(arrayOf: editSchema, maximumElements: 3))
                ]), dependencies: [])
                let result = try await session.respond(to: input.prompt, schema: schema, options: options)
                let edits = try result.content.value([GeneratedContent].self, forProperty: "edits")
                full = try CopilotAdapter.apply(edits.map {
                    .init(find: try $0.value(String.self, forProperty: "find"), replace: try $0.value(String.self, forProperty: "replace"))
                }, original: input.original ?? "")
            } else {
              let stream = session.streamResponse(to: input.prompt, options: options)
              for try await snapshot in stream {
                try Task.checkCancellation()
                full = snapshot.content
                guard full.hasPrefix(emitted) else {
                    throw APIError("unstable_output", "生成済みの内容が変更されたため補完を停止しました。", status: .unprocessableContent)
                }
                let match = input.stops.compactMap { full.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
                let visible: String
                if let match { visible = String(full[..<match.lowerBound]); stopFound = true }
                else {
                    var held = 0
                    for stop in input.stops {
                        for length in 1..<max(1, stop.count) {
                            if full.hasSuffix(String(stop.prefix(length))) { held = max(held, length) }
                        }
                    }
                    visible = String(full.dropLast(held))
                }
                if visible.count > emitted.count {
                    let delta = String(visible.dropFirst(emitted.count))
                    if first == nil { first = Self.milliseconds(since: started) }
                    emit(.delta(delta))
                    emitted = visible
                }
                if stopFound { break }
              }
            }
            try Task.checkCancellation()
            if input.task == .nes {
                let response = full
                if input.stops.contains(where: { response.contains($0) }) {
                    throw APIError("incomplete_edit", "停止文字列が編集応答を分断するため提案を破棄しました。", status: .unprocessableContent)
                }
                if !response.isEmpty { first = Self.milliseconds(since: started); emit(.delta(response)) }
                count = response.count
            } else {
                if !stopFound && full.count > emitted.count { emit(.delta(String(full.dropFirst(emitted.count)))) }
                count = stopFound ? emitted.count : full.count
            }
            completed += 1
            last = .init(model: input.model, promptVersion: input.promptVersion,
                         firstContentMilliseconds: first, totalMilliseconds: Self.milliseconds(since: started),
                         outputCharacters: count, outcome: "completed")
            publishHealth()
            emit(.done("stop"))
        } catch {
            if error is CancellationError || Task.isCancelled { cancelled += 1 }
            else { failed += 1 }
            last = .init(model: input.model, promptVersion: input.promptVersion,
                         firstContentMilliseconds: first, totalMilliseconds: Self.milliseconds(since: started),
                         outputCharacters: count, outcome: Task.isCancelled ? "cancelled" : "failed")
            publishHealth()
            throw error
        }
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let duration = instant.duration(to: .now).components
        return Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}

func apiError(_ error: any Error) -> APIError {
    if let error = error as? APIError { return error }
    if error is CancellationError { return APIError("cancelled", "リクエストがキャンセルされました。", status: .requestTimeout) }
    if let error = error as? LanguageModelSession.GenerationError {
        switch error {
        case .exceededContextWindowSize: return APIError("context_length_exceeded", "モデルのコンテキスト上限を超えました。")
        case .assetsUnavailable: return APIError("model_unavailable", "モデルの準備ができていません。", status: .serviceUnavailable)
        case .guardrailViolation, .refusal: return APIError("model_refusal", "モデルがこの生成を拒否しました。", status: .unprocessableContent)
        case .rateLimited, .concurrentRequests: return APIError("model_busy", "モデルが使用中です。", status: .tooManyRequests)
        default: return APIError("generation_failed", "モデルの生成に失敗しました。", status: .unprocessableContent)
        }
    }
    let native = error as NSError
    if native.domain.hasPrefix("FoundationModels.") {
        return APIError("generation_failed", "モデルが完全な応答を生成できませんでした。提案を破棄しました。", status: .unprocessableContent)
    }
    return APIError("generation_failed", "生成処理に失敗しました。", status: .internalServerError)
}
