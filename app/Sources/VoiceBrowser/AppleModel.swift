import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Foundation Models, the model behind Apple Intelligence).
/// Built into macOS 26+, nothing to download or keep running, so it is the default on a Mac that has it.
/// Used through `Brain.chat` like an Ollama model, with the pseudo model name `AppleModel.id`.
enum AppleModel {
    static let id = "apple:on-device"
    static let label = "Apple on-device"

    /// True when this Mac can run it right now (macOS 26+, Apple Silicon, Apple Intelligence on, model downloaded).
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Why it isn't available, for the log. Nil when it is.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let why): return "Apple's on-device model is unavailable (\(why))"
            }
        }
        #endif
        return "Apple's on-device model needs macOS 26 or later"
    }

    /// System messages become the model's instructions, everything else the prompt.
    /// With `schema` (a JSON schema as used for Ollama) the reply is constrained to match it and returned as JSON text.
    static func chat(_ messages: [[String: String]], schema: [String: Any]?) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
            let prompt = messages.filter { $0["role"] != "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
            let session = LanguageModelSession(model: .default, instructions: instructions.isEmpty ? nil : instructions)
            let options = GenerationOptions(temperature: 0)
            do {
                if let schema {
                    let response = try await session.respond(to: prompt, schema: try generationSchema(schema), options: options)
                    return response.content.jsonString
                }
                return try await session.respond(to: prompt, options: options).content
            } catch let e as BrainError {
                throw e
            } catch {
                throw BrainError.bad("Apple on-device model: \(error.localizedDescription)")
            }
        }
        #endif
        throw BrainError.bad(unavailableReason ?? "Apple's on-device model isn't available")
    }

    #if canImport(FoundationModels)
    /// A small JSON-schema subset (object of string / integer / boolean / string-enum properties) as a Foundation Models schema.
    @available(macOS 26.0, *)
    static func generationSchema(_ json: [String: Any]) throws -> GenerationSchema {
        let props = json["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set(json["required"] as? [String] ?? [])
        let properties: [DynamicGenerationSchema.Property] = props.keys.sorted().map { name in
            let p = props[name]!
            let schema: DynamicGenerationSchema
            if let choices = p["enum"] as? [String] {
                schema = DynamicGenerationSchema(name: name, anyOf: choices)
            } else {
                switch p["type"] as? String {
                case "integer": schema = DynamicGenerationSchema(type: Int.self)
                case "boolean": schema = DynamicGenerationSchema(type: Bool.self)
                default: schema = DynamicGenerationSchema(type: String.self)
                }
            }
            return DynamicGenerationSchema.Property(name: name, schema: schema, isOptional: !required.contains(name))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "Action", properties: properties), dependencies: [])
    }
    #endif
}
