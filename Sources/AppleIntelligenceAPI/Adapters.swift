import Foundation

struct PreparedRequest: Sendable {
    let model: String
    let task: ModelProfile.TaskKind
    let instructions: String
    let prompt: String
    let original: String?
    let maxTokens: Int
    let temperature: Double
    let topP: Double?
    let stops: [String]
    let timeoutSeconds: Int
    let promptVersion: String
    let language: String

    static func prepare(_ request: CompletionRequest, configuration: Configuration, root: URL, chat: Bool) throws -> Self {
        try request.validate()
        guard let profile = configuration.models[request.model] else {
            throw APIError("model_not_found", "指定されたモデルはありません。", status: .notFound)
        }
        guard chat == (profile.task == .nes) else {
            throw APIError("unsupported_endpoint", "inlineは/completions、NESは/chat/completionsを使用してください。")
        }
        let language = request.language ?? detectLanguage(request)
        let promptConfiguration = try PromptConfiguration.load(from: root, configuration: configuration)
        guard let promptProfile = promptConfiguration.models[request.model] else {
            throw APIError("invalid_prompt_configuration", "モデルのプロンプト設定がありません。", status: .serviceUnavailable)
        }
        let selected = promptProfile.selected(language: language)
        let instructions = selected.instructions
        let maxTokens = min(request.maxTokens ?? profile.maxOutputTokens, profile.maxOutputTokens)
        // SDK 26には公開tokenizerがないため、コードを保守的に概算。実際の超過はAPIエラーとして返す。
        let budget = configuration.contextTokens - configuration.safetyTokens - maxTokens - estimatedTokens(instructions)
        guard budget > 128 else { throw APIError("context_length_exceeded", "用途別プロンプトが長すぎます。") }
        let result: AdapterInput
        switch profile.adapter {
        case "fim": result = try FIMAdapter.prepare(request, budget: budget, template: selected.template)
        case "copilot-completions":
            guard let renameHintTemplate = selected.renameHintTemplate else {
                throw APIError("invalid_prompt_configuration", "NESのrenameテンプレートがありません。", status: .serviceUnavailable)
            }
            result = try CopilotAdapter.prepare(request, budget: budget, template: selected.template,
                                                renameHintTemplate: renameHintTemplate)
        default: throw APIError("unsupported_adapter", "未対応のアダプターです。")
        }
        // 安定した識別値。プロンプト本文はログや通知へ出さない。
        let versionSource = instructions + "\u{0}" + selected.template + "\u{0}" + (selected.renameHintTemplate ?? "")
        let version = versionSource.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Self(model: request.model, task: profile.task, instructions: instructions,
                    prompt: result.prompt, original: result.original, maxTokens: maxTokens,
                    temperature: request.temperature ?? profile.temperature, topP: request.topP,
                    stops: request.stop?.strings ?? [], timeoutSeconds: configuration.timeoutSeconds,
                    promptVersion: String(version, radix: 16), language: language)
    }

    static func detectLanguage(_ request: CompletionRequest) -> String {
        let text = request.prompt ?? request.messages?.last(where: { $0.role == "user" })?.content ?? ""
        for pattern in ["(?:#|//) language: ([a-zA-Z0-9_-]+)", "current document is ([a-zA-Z0-9_-]+)"] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) { return String(text[range]) }
        }
        return "unknown"
    }
}

struct AdapterInput { let prompt: String; let original: String? }

func estimatedTokens(_ text: String) -> Int {
    let ascii = text.unicodeScalars.filter(\.isASCII).count
    return (ascii + 1) / 2 + (text.unicodeScalars.count - ascii) * 2
}

func clipped(_ text: String, budget: Int, tail: Bool) -> String {
    guard budget > 0 else { return "" }
    var count = 0
    var scalars: [Unicode.Scalar] = []
    let source = tail ? Array(text.unicodeScalars.reversed()) : Array(text.unicodeScalars)
    for scalar in source {
        count += scalar.isASCII ? 1 : 4
        if count > budget * 2 { break }
        scalars.append(scalar)
    }
    return String(String.UnicodeScalarView(tail ? scalars.reversed() : scalars))
}

func renderedTemplate(_ template: String, values: [String: String]) -> String {
    var result = ""
    var cursor = template.startIndex
    while cursor < template.endIndex {
        let next = values.compactMap { placeholder, value -> (Range<String.Index>, String)? in
            template.range(of: placeholder, range: cursor..<template.endIndex).map { ($0, value) }
        }.min { $0.0.lowerBound < $1.0.lowerBound }
        guard let (range, value) = next else { break }
        result += template[cursor..<range.lowerBound]
        result += value
        cursor = range.upperBound
    }
    result += template[cursor..<template.endIndex]
    return result
}

enum FIMAdapter {
    static func prepare(_ request: CompletionRequest, budget: Int, template: String) throws -> AdapterInput {
        guard let text = request.prompt,
              text.hasPrefix("<|fim_prefix|>"),
              let suffixTag = text.range(of: "<|fim_suffix|>"),
              text.hasSuffix("<|fim_middle|>") else {
            throw APIError("invalid_fim_prompt", "FIMのprefix/suffix/middleマーカーが必要です。")
        }
        var prefix = String(text[text.index(text.startIndex, offsetBy: "<|fim_prefix|>".count)..<suffixTag.lowerBound])
        var suffix = String(text[suffixTag.upperBound..<text.index(text.endIndex, offsetBy: -"<|fim_middle|>".count)])
        // 候補拡張が付けるメタデータ行とsuffixの包み改行を本文から外す。
        if prefix.hasPrefix("\n# language: ") || prefix.hasPrefix("\n// language: ") {
            prefix.removeFirst()
            if let endOfHeader = prefix.firstIndex(of: "\n") { prefix = String(prefix[prefix.index(after: endOfHeader)...]) }
            if suffix.hasPrefix("\n") { suffix.removeFirst() }
            if suffix.hasSuffix("\n") { suffix.removeLast() }
        }
        let emptyTemplate = renderedTemplate(template, values: ["{before}": "", "{after}": ""])
        let remaining = budget - estimatedTokens(emptyTemplate)
        guard remaining > 0 else { throw APIError("context_length_exceeded", "プロンプトテンプレートが長すぎます。") }
        let suffixBudget = min(estimatedTokens(suffix), remaining / 3)
        let before = clipped(prefix, budget: remaining - suffixBudget, tail: true)
        let after = clipped(suffix, budget: suffixBudget, tail: false)
        return .init(prompt: renderedTemplate(template, values: ["{before}": before, "{after}": after]), original: nil)
    }
}

enum CopilotAdapter {
    struct Edit: Sendable, Hashable { let find: String; let replace: String }
    static let start = "###remain edit start boundary line###"
    static let end = "###remain edit end boundary line###"

    static func section(_ name: String, in text: String) -> String? {
        let opening = "<|\(name)|>\n"
        guard let from = text.range(of: opening),
              let to = text.range(of: "\n<|/\(name)|>", range: from.upperBound..<text.endIndex) else { return nil }
        return String(text[from.upperBound..<to.lowerBound])
    }

    static func prepare(_ request: CompletionRequest, budget: Int, template: String,
                        renameHintTemplate: String) throws -> AdapterInput {
        guard let messages = request.messages,
              let text = messages.last(where: { $0.role == "user" })?.content.replacingOccurrences(of: "\r\n", with: "\n"),
              let window = section("code_to_edit", in: text),
              window.hasPrefix(start + "\n"), window.hasSuffix("\n" + end) else {
            throw APIError("invalid_nes_prompt", "copilot-completionsの編集範囲が見つかりません。")
        }
        let target = String(window.dropFirst(start.count + 1).dropLast(end.count + 1))
        let original = target.replacingOccurrences(of: "<|cursor|>", with: "")
        let emptyTemplate = renderedTemplate(template, values: [
            "{recentEdits}": "", "{beforeTarget}": "", "{afterTarget}": "", "{target}": ""
        ])
        var remaining = budget - estimatedTokens(emptyTemplate) - estimatedTokens(target)
        guard remaining >= 0 else {
            throw APIError("context_length_exceeded", "編集対象が大きすぎます。対象範囲を小さくしてください。")
        }
        let rawHistory = section("edit_diff_history", in: text) ?? ""
        let hint = renameHint(rawHistory, template: renameHintTemplate)
        let recent = hint.isEmpty ? clipped(rawHistory, budget: remaining / 2, tail: true) : hint
        remaining -= estimatedTokens(recent)
        guard remaining >= 0 else {
            throw APIError("context_length_exceeded", "renameテンプレートが長すぎます。")
        }
        let before = clipped(section("area_code_prefix", in: text) ?? "", budget: remaining / 2, tail: true)
        remaining -= estimatedTokens(before)
        let after = clipped(section("area_code_suffix", in: text) ?? "", budget: remaining, tail: false)
        // 明確なrenameは意味に変換する。小型モデルが完了済みのdiffを再出力するのを避ける。
        let prompt = renderedTemplate(template, values: [
            "{recentEdits}": recent, "{beforeTarget}": before, "{afterTarget}": after, "{target}": target
        ])
        return .init(prompt: prompt, original: original)
    }

    // 直近の一行変更で識別子が一つだけ変わった場合、その事実を明示する。
    // 出力の置換は行わず、モデルへ渡す編集履歴を読み取りやすくする。
    static func renameHint(_ history: String, template: String) -> String {
        let lines = history.split(separator: "\n").map(String.init)
        guard let addedIndex = lines.lastIndex(where: { $0.hasPrefix("+") && !$0.hasPrefix("+++") }),
              let old = lines[..<addedIndex].last(where: { $0.hasPrefix("-") && !$0.hasPrefix("---") }),
              let regex = try? NSRegularExpression(pattern: "[\\p{L}_][\\p{L}\\p{N}_]*") else { return "" }
        func words(_ line: String) -> [String] {
            regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
                Range($0.range, in: line).map { String(line[$0]) }
            }
        }
        let before = words(old), after = words(lines[addedIndex])
        guard before.count == after.count else { return "" }
        let changes = zip(before, after).filter { $0 != $1 }
        guard changes.count == 1, let change = changes.first else { return "" }
        var oldToken = change.0, newToken = change.1
        if !oldToken.unicodeScalars.allSatisfy(\.isASCII) || !newToken.unicodeScalars.allSatisfy(\.isASCII) {
            while oldToken.count > 1 && newToken.count > 1 && oldToken.first == newToken.first { oldToken.removeFirst(); newToken.removeFirst() }
            while oldToken.count > 1 && newToken.count > 1 && oldToken.last == newToken.last { oldToken.removeLast(); newToken.removeLast() }
        }
        guard estimatedTokens(oldToken + newToken) < 64 else { return "" }
        return renderedTemplate(template, values: ["{old}": oldToken, "{new}": newToken])
    }

    static func response(_ text: String, original: String) throws -> String {
        var revised = text.replacingOccurrences(of: "<|cursor|>", with: "")
        let originalNewlines = original.reversed().prefix(while: { $0 == "\n" }).count
        while revised.hasSuffix("\n") { revised.removeLast() }
        revised += String(repeating: "\n", count: originalNewlines)
        guard !(revised.hasPrefix("```") && !original.hasPrefix("```")),
              !revised.contains(start), !revised.contains(end),
              !revised.contains("</TARGET>"), !revised.contains("<TARGET>"),
              !(revised.isEmpty && !original.isEmpty) else {
            throw APIError("invalid_edit", "編集応答の形式が不正です。提案を破棄しました。", status: .unprocessableContent)
        }
        if revised == original { return "" }
        return start + "\n" + revised + "\n" + end
    }

    static func apply(_ edits: [Edit], original: String) throws -> String {
        var changes: [(Range<String.Index>, String)] = []
        func identifier(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
        var seen = Set<Edit>()
        for edit in edits where edit.find != edit.replace && seen.insert(edit).inserted {
            guard !edit.find.isEmpty, !edit.find.contains("<|cursor|>"), !edit.replace.contains("<|cursor|>") else {
                throw APIError("invalid_edit", "空の検索文字列やカーソルタグを含む編集は適用できません。", status: .unprocessableContent)
            }
            var matches: [Range<String.Index>] = []
            var from = original.startIndex
            while let match = original.range(of: edit.find, range: from..<original.endIndex) {
                let leftInside = identifier(edit.find.first!) && match.lowerBound > original.startIndex && identifier(original[original.index(before: match.lowerBound)])
                let rightInside = identifier(edit.find.last!) && match.upperBound < original.endIndex && identifier(original[match.upperBound])
                if !leftInside && !rightInside { matches.append(match) }
                from = match.upperBound
            }
            guard !matches.isEmpty else { throw APIError("edit_not_found", "変更前の文字列が編集対象に存在しません。", status: .unprocessableContent) }
            guard matches.count == 1, let match = matches.first else {
                throw APIError("ambiguous_edit", "編集位置が複数あるため提案を破棄しました。", status: .unprocessableContent)
            }
            guard !changes.contains(where: { $0.0.overlaps(match) }) else {
                throw APIError("overlapping_edits", "編集範囲が重複するため提案を破棄しました。", status: .unprocessableContent)
            }
            changes.append((match, edit.replace))
        }
        var revised = original
        for (range, replacement) in changes.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            revised.replaceSubrange(range, with: replacement)
        }
        return try response(revised, original: original)
    }
}
