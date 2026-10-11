import Foundation
import Security

/// API keys live in the login Keychain, never in preferences or logs.
enum Keychain {
    private static let service = "com.focal55.ode.api-keys"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, for account: String) -> OSStatus {
        delete(account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

enum Provider: String, Codable, CaseIterable, Identifiable {
    case onDevice, anthropic, openAI, local
    var id: Self { self }

    var name: String {
        switch self {
        case .onDevice: "Apple on-device"
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .local: "Local (LM Studio)"
        }
    }

    /// Local servers run on this Mac, so they need no consent or redaction.
    var leavesTheMac: Bool { self == .anthropic || self == .openAI }
}

struct Usage: Equatable {
    var input = 0
    var output = 0
}

/// One structured request: instructions, the conversation excerpt, and the JSON schema the
/// answer must follow.
struct CloudRequest {
    let system: String
    let prompt: String
    let schemaName: String
    let schema: [String: Any]
    var effort = "low"
}

enum CloudError: Error, Equatable {
    case missingKey
    case refused
    case http(Int, String)
    case malformed
}

enum CloudClient {
    /// Models Ode knows how to call and price, strongest first. The key's own model list
    /// decides which of these appear; anything without a price here can't respect the cap.
    static let anthropicModels = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    /// Dollars per million tokens, input then output, from Anthropic's published rates.
    static let anthropicPrices: [String: (input: Double, output: Double)] = [
        "claude-fable-5-1": (10, 50), "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.10, 0.50),
    ]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Non-streaming calls are silent until done, and Fable can think for minutes.
        configuration.timeoutIntervalForRequest = 600
        return URLSession(configuration: configuration)
    }()

    /// Raw HTTP to the Messages API; Swift has no official SDK. Structured output uses
    /// output_config.format, since forced tool choice is rejected by current models.
    static func anthropic(key: String, model: String, _ request: CloudRequest) async throws -> (Data, Usage) {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": request.system,
            "messages": [["role": "user", "content": request.prompt]],
            "output_config": ["format": ["type": "json_schema", "schema": request.schema], "effort": request.effort],
        ]
        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // On a safety decline the API re-runs the request on a model chosen for that category.
        if model != "claude-haiku-5-5" {
            body["fallbacks"] = "default"
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(urlRequest)
        guard json["stop_reason"] as? String != "refusal" else { throw CloudError.refused }
        let content = json["content"] as? [[String: Any]] ?? []
        guard let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else { throw CloudError.malformed }
        let usage = json["usage"] as? [String: Any]
        return (Data(text.utf8), Usage(input: usage?["input_tokens"] as? Int ?? 0, output: usage?["output_tokens"] as? Int ?? 0))
    }

    /// OpenAI's chat completions shape, which LM Studio's local server also speaks.
    static func openAICompatible(baseURL: URL, key: String?, model: String, _ request: CloudRequest) async throws -> (Data, Usage) {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": request.prompt]],
            "response_format": ["type": "json_schema", "json_schema": ["name": request.schemaName, "strict": true, "schema": request.schema]],
        ]
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(urlRequest)
        let choices = json["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard message?["refusal"] as? String == nil else { throw CloudError.refused }
        // LM Studio puts a reasoning model's constrained answer in reasoning_content and leaves content empty.
        let content = (message?["content"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard let text = content ?? message?["reasoning_content"] as? String else { throw CloudError.malformed }
        let usage = json["usage"] as? [String: Any]
        return (Data(text.utf8), Usage(input: usage?["prompt_tokens"] as? Int ?? 0, output: usage?["completion_tokens"] as? Int ?? 0))
    }

    /// Model ids a key or local server can use; also how keys are verified.
    static func models(provider: Provider, key: String?, localBaseURL: URL) async throws -> [String] {
        let url: URL
        var request: URLRequest
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/models")!
            request = URLRequest(url: url)
            request.setValue("Bearer \(key ?? "")", forHTTPHeaderField: "Authorization")
        case .local:
            request = URLRequest(url: localBaseURL.appendingPathComponent("models"))
        case .onDevice:
            return []
        }
        let json = try await send(request)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.malformed }
        return json
    }
}

/// JSON schemas and decodable shapes mirroring the on-device @Generable types.
enum CloudSchemas {
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }

    struct Verdict: Decodable { let isPromise: Bool; let task: String; let status: String }
    static let verdict = object([
        "isPromise": ["type": "boolean", "description": "True if You committed to do something specific for or with the others, including offers like 'let me ask' or 'I'll check'. Saying you are on your way, and quick acknowledgements, are not promises."],
        "task": ["type": "string", "description": "The promised task in six words or fewer, starting with a verb."],
        "status": ["type": "string", "enum": ["open", "done", "unclear"]],
    ])

    struct Topics: Decodable { let topics: [String] }
    static let topics = object(["topics": ["type": "array", "items": ["type": "string"],
                                           "description": "Three to six short lowercase topics, two or three words each."]])

    struct ReminderDTO: Decodable { let when: String; let text: String }
    struct Reminders: Decodable { let items: [ReminderDTO] }
    static let reminders = object(["items": ["type": "array", "items": object([
        "when": ["type": "string", "description": "When it happens, as written."],
        "text": ["type": "string", "description": "What to remember, in under twelve words."],
    ])]])
}
