import Foundation
import Hummingbird

struct ErrorEnvelope: Encodable {
    struct Detail: Encodable { let message: String; let type: String; let code: String }
    let error: Detail
    init(_ error: APIError) {
        self.error = .init(message: error.message, type: "apple_completion_error", code: error.code)
    }
}

struct CompletionEnvelope: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    struct Delta: Encodable { let content: String }
    struct Choice: Encodable {
        let index = 0
        let text: String?
        let message: Message?
        let delta: Delta?
        let finish_reason: String?
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]

    init(id: String, model: String, text: String, chat: Bool, stream: Bool, finish: String?) {
        self.id = id
        self.model = model
        self.created = Int(Date().timeIntervalSince1970)
        self.object = chat ? (stream ? "chat.completion.chunk" : "chat.completion") : "text_completion"
        self.choices = [.init(text: chat ? nil : text,
                              message: chat && !stream ? .init(role: "assistant", content: text) : nil,
                              delta: chat && stream ? .init(content: text) : nil, finish_reason: finish)]
    }
}

func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: status, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

struct Server: Sendable {
    let root: URL
    let engine = Engine()

    func generation(_ input: PreparedRequest) -> (AsyncThrowingStream<GenerationEvent, any Error>, Task<Void, Never>) {
        let (events, continuation) = AsyncThrowingStream<GenerationEvent, any Error>.makeStream()
        let producer = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await engine.generate(input) { continuation.yield($0) } }
                    group.addTask {
                        try await Task.sleep(for: .seconds(input.timeoutSeconds))
                        throw APIError("generation_timeout", "生成が制限時間を超えました。", status: .gatewayTimeout)
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            continuation.yield(.heartbeat)
                            try await Task.sleep(for: .seconds(1))
                        }
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in producer.cancel() }
        return (events, producer)
    }

    func completion(_ request: Request, context: BasicRequestContext, chat: Bool) async throws -> Response {
        do {
            let configuration = try Configuration.load(from: root)
            let buffer = try await request.body.collect(upTo: 1_048_576)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let body: CompletionRequest
            do { body = try decoder.decode(CompletionRequest.self, from: Data(buffer.readableBytesView)) }
            catch { throw APIError("invalid_request", "リクエストのJSON形式が不正です。") }
            let input = try PreparedRequest.prepare(body, configuration: configuration, root: root, chat: chat)
            let id = "cmpl-" + UUID().uuidString
            if body.stream == true {
                return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"], body: .init { writer in
                    let (events, producer) = generation(input)
                    defer { producer.cancel() }
                    do {
                        for try await event in events {
                            let line: String
                            switch event {
                            case .heartbeat: line = ": keep-alive\n\n"
                            case .delta(let text):
                                let envelope = CompletionEnvelope(id: id, model: input.model, text: text, chat: chat, stream: true, finish: nil)
                                line = "data: " + String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self) + "\n\n"
                            case .done(let reason):
                                let envelope = CompletionEnvelope(id: id, model: input.model, text: "", chat: chat, stream: true, finish: reason)
                                line = "data: " + String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
                            }
                            try await writer.write(ByteBuffer(string: line))
                        }
                    } catch {
                        producer.cancel()
                        let data = try JSONEncoder().encode(ErrorEnvelope(apiError(error)))
                        try await writer.write(ByteBuffer(string: "data: " + String(decoding: data, as: UTF8.self) + "\n\ndata: [DONE]\n\n"))
                    }
                    try await writer.finish(nil)
                })
            }
            let (events, producer) = generation(input)
            defer { producer.cancel() }
            var text = ""
            for try await event in events {
                if case .delta(let delta) = event { text += delta }
            }
            return try jsonResponse(CompletionEnvelope(id: id, model: input.model, text: text, chat: chat, stream: false, finish: "stop"))
        } catch {
            let error = apiError(error)
            return try jsonResponse(ErrorEnvelope(error), status: error.status)
        }
    }
}

@main
struct AppleCompletion {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configHome = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let arguments = CommandLine.arguments
        let root: URL
        if let index = arguments.firstIndex(of: "--config-dir"), arguments.indices.contains(index + 1) {
            root = URL(fileURLWithPath: arguments[index + 1])
        } else { root = configHome.appendingPathComponent("vscode-apple-intelligence-api") }
        let configuration = try Configuration.load(from: root)
        let server = Server(root: root)
        let router = Router()
        router.get("/health") { _, _ in
            do {
                _ = try Configuration.load(from: root)
                let health = await server.engine.health()
                return try jsonResponse(health, status: health.status == "ok" ? .ok : .serviceUnavailable)
            } catch { return try jsonResponse(ErrorEnvelope(apiError(error)), status: .serviceUnavailable) }
        }
        router.get("/health/events") { _, _ in
            Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"], body: .init { writer in
                let (id, events) = await server.engine.subscribeHealth()
                defer { Task { await server.engine.unsubscribeHealth(id) } }
                for await health in events {
                    let data = try JSONEncoder().encode(health)
                    try await writer.write(ByteBuffer(string: "data: " + String(decoding: data, as: UTF8.self) + "\n\n"))
                }
                try await writer.finish(nil)
            })
        }
        router.get("/v1/models") { _, _ in
            struct Models: Encodable {
                struct Model: Encodable { let id: String; let object = "model"; let owned_by = "apple-local" }
                let object = "list"
                let data: [Model]
            }
            do {
                let config = try Configuration.load(from: root)
                return try jsonResponse(Models(data: config.models.keys.sorted().map { .init(id: $0) }))
            } catch { return try jsonResponse(ErrorEnvelope(apiError(error)), status: .serviceUnavailable) }
        }
        router.post("/v1/completions") { request, context in
            try await server.completion(request, context: context, chat: false)
        }
        router.post("/v1/chat/completions") { request, context in
            try await server.completion(request, context: context, chat: true)
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: configuration.port), serverName: "vscode-apple-intelligence-api"))
        try await app.runService()
    }
}
