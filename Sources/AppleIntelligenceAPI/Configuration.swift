import Foundation
import Hummingbird

struct APIError: Error, Sendable {
    let status: HTTPResponse.Status
    let code: String
    let message: String

    init(_ code: String, _ message: String, status: HTTPResponse.Status = .badRequest) {
        self.status = status
        self.code = code
        self.message = message
    }
}

struct Configuration: Decodable, Sendable {
    let port: Int
    let contextTokens: Int
    let safetyTokens: Int
    let timeoutSeconds: Int
    let languagePromptFiles: [String: String]
    let models: [String: ModelProfile]

    static func load(from root: URL) throws -> Self {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let value = try decoder.decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("config.json")))
            guard (1024...65535).contains(value.port),
                  (1024...4096).contains(value.contextTokens),
                  value.safetyTokens >= 256, value.safetyTokens < value.contextTokens,
                  (1...120).contains(value.timeoutSeconds), !value.models.isEmpty else {
                throw APIError("invalid_configuration", "設定の範囲が不正です。", status: .serviceUnavailable)
            }
            for profile in value.models.values {
                guard profile.maxOutputTokens > 0,
                      profile.maxOutputTokens + value.safetyTokens < value.contextTokens,
                      (0...2).contains(profile.temperature),
                      !profile.promptFile.hasPrefix("/"),
                      !profile.promptFile.split(separator: "/").contains("..") else {
                    throw APIError("invalid_configuration", "モデル設定が不正です。", status: .serviceUnavailable)
                }
                guard (profile.task == .inline && profile.adapter == "fim") ||
                      (profile.task == .nes && profile.adapter == "copilot-completions") else {
                    throw APIError("unsupported_adapter", "用途に対応するアダプターを指定してください。", status: .serviceUnavailable)
                }
            }
            return value
        } catch let error as APIError { throw error }
        catch { throw APIError("invalid_configuration", "config.jsonを読み込めません。", status: .serviceUnavailable) }
    }
}

struct ModelProfile: Decodable, Sendable {
    enum TaskKind: String, Decodable, Sendable { case inline, nes }
    let task: TaskKind
    let adapter: String
    let promptFile: String
    let languagePromptFiles: [String: String]
    let maxOutputTokens: Int
    let temperature: Double
}

struct CompletionRequest: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: String
    }
    let model: String
    let language: String?
    let prompt: String?
    let messages: [Message]?
    let stream: Bool?
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let n: Int?
    let presencePenalty: Double?
    let frequencyPenalty: Double?
    let stop: StopSequences?

    enum StopSequences: Decodable, Sendable {
        case values([String])
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { self = .values([string]) }
            else { self = .values(try container.decode([String].self)) }
        }
        var strings: [String] { switch self { case .values(let values): values } }
    }

    func validate() throws {
        guard n == nil || n == 1 else { throw APIError("unsupported_parameter", "nは1のみ対応します。") }
        guard presencePenalty == nil || presencePenalty == 0,
              frequencyPenalty == nil || frequencyPenalty == 0 else {
            throw APIError("unsupported_parameter", "presence_penaltyとfrequency_penaltyは0に設定してください。")
        }
        guard maxTokens == nil || maxTokens! > 0,
              temperature == nil || (0...2).contains(temperature!),
              topP == nil || (0...1).contains(topP!) else {
            throw APIError("invalid_parameter", "生成パラメーターが範囲外です。")
        }
        guard !(stop?.strings.contains("") ?? false) else {
            throw APIError("invalid_stop", "空の停止文字列は指定できません。")
        }
    }
}
