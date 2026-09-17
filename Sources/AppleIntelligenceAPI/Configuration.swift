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
                      (0...2).contains(profile.temperature) else {
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
    let maxOutputTokens: Int
    let temperature: Double
}

struct PromptConfiguration: Decodable, Sendable {
    struct Profile: Decodable, Sendable {
        let instructions: String
        let languageInstructions: [String: String]
        let promptTemplate: String
        let languagePromptTemplates: [String: String]
        let renameHintTemplate: String?
        let languageRenameHintTemplates: [String: String]?

        func selected(language: String) -> (instructions: String, template: String, renameHintTemplate: String?) {
            (languageInstructions[language] ?? instructions,
             languagePromptTemplates[language] ?? promptTemplate,
             languageRenameHintTemplates?[language] ?? renameHintTemplate)
        }
    }

    let models: [String: Profile]
    let validationErrors: [String]

    static func load(from root: URL, configuration: Configuration) throws -> Self {
        let value: Self
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            value = try decoder.decode(Self.self, from: Data(contentsOf: root.appendingPathComponent("prompt-settings.json")))
        } catch {
            throw APIError("invalid_prompt_configuration", "VS Codeのプロンプト設定を読み込めません。", status: .serviceUnavailable)
        }
        guard value.validationErrors.isEmpty else {
            throw APIError("invalid_prompt_configuration", value.validationErrors.joined(separator: " "), status: .serviceUnavailable)
        }
        guard Set(value.models.keys) == Set(configuration.models.keys) else {
            throw APIError("invalid_prompt_configuration", "全モデルのプロンプト設定が必要です。", status: .serviceUnavailable)
        }
        for (model, modelConfiguration) in configuration.models {
            guard let profile = value.models[model] else { continue }
            try validate(profile.instructions, label: "\(model)の指示プロンプト")
            for (language, instructions) in profile.languageInstructions {
                guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw APIError("invalid_prompt_configuration", "言語IDを空にできません。", status: .serviceUnavailable)
                }
                try validate(instructions, label: "\(model)/\(language)の指示プロンプト")
            }
            try validateTemplate(profile.promptTemplate, adapter: modelConfiguration.adapter, label: "\(model)のテンプレート")
            for (language, template) in profile.languagePromptTemplates {
                guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw APIError("invalid_prompt_configuration", "言語IDを空にできません。", status: .serviceUnavailable)
                }
                try validateTemplate(template, adapter: modelConfiguration.adapter, label: "\(model)/\(language)のテンプレート")
            }
            if modelConfiguration.adapter == "copilot-completions" {
                guard let renameHintTemplate = profile.renameHintTemplate else {
                    throw APIError("invalid_prompt_configuration", "\(model)のrenameテンプレートが必要です。", status: .serviceUnavailable)
                }
                try validateRenameTemplate(renameHintTemplate, label: "\(model)のrenameテンプレート")
                for (language, template) in profile.languageRenameHintTemplates ?? [:] {
                    guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw APIError("invalid_prompt_configuration", "言語IDを空にできません。", status: .serviceUnavailable)
                    }
                    try validateRenameTemplate(template, label: "\(model)/\(language)のrenameテンプレート")
                }
            }
        }
        return value
    }

    private static func validate(_ value: String, label: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError("invalid_prompt_configuration", "\(label)を空にできません。", status: .serviceUnavailable)
        }
    }

    private static func validateTemplate(_ template: String, adapter: String, label: String) throws {
        let placeholders: [String]
        switch adapter {
        case "fim": placeholders = ["{before}", "{after}"]
        case "copilot-completions": placeholders = ["{recentEdits}", "{beforeTarget}", "{afterTarget}", "{target}"]
        default: return
        }
        for placeholder in placeholders where template.components(separatedBy: placeholder).count != 2 {
            throw APIError("invalid_prompt_configuration", "\(label)には\(placeholder)を1回だけ指定してください。", status: .serviceUnavailable)
        }
    }

    private static func validateRenameTemplate(_ template: String, label: String) throws {
        for placeholder in ["{old}", "{new}"] where template.components(separatedBy: placeholder).count != 2 {
            throw APIError("invalid_prompt_configuration", "\(label)には\(placeholder)を1回だけ指定してください。", status: .serviceUnavailable)
        }
    }
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
