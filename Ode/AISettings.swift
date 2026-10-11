import Foundation
import OdeCore
import Observation
import Security

enum AIJob: String, CaseIterable, Identifiable, Codable {
    case quickReads, deepAnalysis, drafting
    var id: Self { self }

    var title: String {
        switch self {
        case .quickReads: "Quick reads"
        case .deepAnalysis: "Deep analysis"
        case .drafting: "Drafting"
        }
    }

    var detail: String {
        switch self {
        case .quickReads: "Open-loop checks"
        case .deepAnalysis: "Recurring topics and things to remember"
        case .drafting: "Replies in your voice"
        }
    }
}

struct Route: Codable, Hashable {
    var provider: Provider
    var model: String

    static let onDevice = Route(provider: .onDevice, model: "Apple on-device")
}

struct ConsentRequest: Identifiable {
    let id = UUID()
    let conversation: String
    let provider: Provider
    let resolve: (Bool) -> Void
}

typealias CloudRunner = (CloudRequest) async -> Data?

/// Which model handles which job, the keys behind them, and the rules every cloud call
/// passes through: consent, redaction, Family-only-on-device and the monthly cap.
@MainActor @Observable
final class AISettings {
    /// Cloud providers are hidden while Ode proves itself on this Mac alone; routes saved to
    /// them run on device instead.
    static let cloudEnabled = false

    private enum Key {
        static let routes = "aiRoutes", localURL = "localBaseURL", ask = "askBeforeCloud", redact = "redactBeforeCloud"
        static let family = "familyOnDevice", cap = "monthlyCap", spend = "cloudSpend", tokens = "cloudTokens", consents = "cloudConsents"
    }

    private let defaults = UserDefaults.standard

    var routes: [AIJob: Route] { didSet { save(routes, Key.routes) } }
    var localBaseURL: String { didSet { defaults.set(localBaseURL, forKey: Key.localURL) } }
    var askBeforeCloud: Bool { didSet { defaults.set(askBeforeCloud, forKey: Key.ask) } }
    var redactBeforeCloud: Bool { didSet { defaults.set(redactBeforeCloud, forKey: Key.redact) } }
    var familyOnDevice: Bool { didSet { defaults.set(familyOnDevice, forKey: Key.family) } }
    var monthlyCap: Double { didSet { defaults.set(monthlyCap, forKey: Key.cap) } }

    private(set) var spend: [String: Double]
    private(set) var tokens: [String: Int]
    private var consents: Set<String>
    private(set) var verified: [Provider: Bool] = [:]
    private(set) var models: [Provider: [String]] = [.anthropic: CloudClient.anthropicModels]
    private(set) var verificationError: [Provider: String] = [:]
    /// Mirrors the Keychain so views refresh when a key is saved or removed.
    private var keys: [Provider: String] = [:]
    var pendingConsent: ConsentRequest?

    init() {
        routes = (defaults.data(forKey: Key.routes).flatMap { try? JSONDecoder().decode([AIJob: Route].self, from: $0) })
            ?? Dictionary(uniqueKeysWithValues: AIJob.allCases.map { ($0, .onDevice) })
        localBaseURL = defaults.string(forKey: Key.localURL) ?? "http://localhost:1234/v1"
        askBeforeCloud = defaults.object(forKey: Key.ask) as? Bool ?? true
        redactBeforeCloud = defaults.object(forKey: Key.redact) as? Bool ?? true
        familyOnDevice = defaults.bool(forKey: Key.family)
        monthlyCap = defaults.object(forKey: Key.cap) as? Double ?? 20
        spend = defaults.dictionary(forKey: Key.spend) as? [String: Double] ?? [:]
        tokens = defaults.dictionary(forKey: Key.tokens) as? [String: Int] ?? [:]
        consents = Set(defaults.stringArray(forKey: Key.consents) ?? [])
        for provider in [Provider.anthropic, .openAI] { keys[provider] = Keychain.read(provider.rawValue) }
    }

    private static var month: String { Date.now.formatted(.iso8601.year().month()) }

    var monthSpend: Double { spend[Self.month] ?? 0 }

    func monthTokens(_ provider: Provider) -> Int { tokens["\(Self.month)|\(provider.rawValue)"] ?? 0 }

    // MARK: Keys

    func hasKey(_ provider: Provider) -> Bool { keys[provider] != nil }

    func maskedKey(_ provider: Provider) -> String? {
        keys[provider].map { key in String(key.prefix(7)) + "•••••••••" + String(key.suffix(4)) }
    }

    /// The Keychain only hands an item back to the app that signed it, so a write that can't
    /// be read back (a stale build still running after a rebuild) is reported, not hidden.
    func saveKey(_ key: String, for provider: Provider) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Keychain.write(key, for: provider.rawValue)
        keys[provider] = Keychain.read(provider.rawValue)
        guard status == errSecSuccess, keys[provider] == key else {
            verified[provider] = false
            verificationError[provider] = status == errSecSuccess
                ? "Saved, but Ode can’t read it back. Quit every copy of Ode and reopen it."
                : "Couldn’t save to the Keychain (error \(status))."
            return
        }
        await verify(provider)
    }

    func removeKey(_ provider: Provider) {
        Keychain.delete(provider.rawValue)
        keys[provider] = nil
        verified[provider] = nil
        verificationError[provider] = nil
        for job in AIJob.allCases where routes[job]?.provider == provider { routes[job] = .onDevice }
    }

    func verify(_ provider: Provider) async {
        do {
            let found = try await CloudClient.models(provider: provider, key: keys[provider], localBaseURL: localURL)
            verified[provider] = true
            verificationError[provider] = nil
            models[provider] = provider == .anthropic
                ? CloudClient.anthropicModels.filter(found.contains)
                : found.filter { !$0.contains("embed") }
        } catch {
            verified[provider] = false
            verificationError[provider] = Self.describe(error)
        }
    }

    private var localURL: URL { URL(string: localBaseURL) ?? URL(string: "http://localhost:1234/v1")! }

    // MARK: Routing

    func route(for job: AIJob, label: Relationship?) -> Route {
        let route = routes[job] ?? .onDevice
        if route.provider.leavesTheMac {
            if !Self.cloudEnabled { return .onDevice }
            if familyOnDevice && label == .family { return .onDevice }
            if route.provider == .anthropic && monthSpend >= monthlyCap { return .onDevice }
            if !hasKey(route.provider) { return .onDevice }
        }
        return route
    }

    /// A runner for one job and conversation, or nil when the job stays on device.
    func runner(for job: AIJob, conversationID: Int64, title: String, label: Relationship?) -> CloudRunner? {
        let route = route(for: job, label: label)
        guard route.provider != .onDevice else { return nil }
        return { [weak self] request in
            await self?.run(request, route: route, conversationID: conversationID, title: title)
        }
    }

    private func run(_ request: CloudRequest, route: Route, conversationID: Int64, title: String) async -> Data? {
        if route.provider.leavesTheMac, askBeforeCloud {
            guard await consent("\(conversationID)|\(route.provider.rawValue)", title: title, provider: route.provider) else { return nil }
        }
        var redactor = Redactor()
        let outgoing = route.provider.leavesTheMac && redactBeforeCloud
            ? CloudRequest(system: request.system, prompt: redactor.redact(request.prompt), schemaName: request.schemaName,
                           schema: request.schema, effort: request.effort)
            : request
        do {
            let (data, usage) = switch route.provider {
            case .anthropic:
                try await CloudClient.anthropic(key: keys[.anthropic] ?? "", model: route.model, outgoing)
            case .openAI:
                try await CloudClient.openAICompatible(baseURL: URL(string: "https://api.openai.com/v1")!,
                                                       key: keys[.openAI], model: route.model, outgoing)
            case .local:
                try await local(outgoing, model: route.model)
            case .onDevice:
                throw CloudError.malformed
            }
            if route.provider == .local { localProblem = nil }
            record(usage, route: route)
            return Data(redactor.restore(String(decoding: data, as: UTF8.self)).utf8)
        } catch {
            if route.provider == .local { localProblem = Self.describeLocal(error, model: route.model) }
            return nil
        }
    }

    /// Why the last LM Studio call failed, in words for the composer; nil after a success.
    private(set) var localProblem: String?

    /// LM Studio keeps every model it has loaded and refuses to load another once memory is
    /// full, so a model left over from other work blocks Ode's. Clearing them and asking once
    /// more loads only the one this request names.
    /// Long enough to keep the model warm through a back-and-forth, short enough that its memory
    /// comes back soon after you stop.
    private static let localIdleUnload = 600

    private func local(_ request: CloudRequest, model: String) async throws -> (Data, Usage) {
        do {
            return try await CloudClient.openAICompatible(baseURL: localURL, key: nil, model: model, idleUnload: Self.localIdleUnload, request)
        } catch CloudError.http(400, let body) where body.contains("Failed to load model") {
            await Task.detached { LMStudio.unloadAll() }.value
            return try await CloudClient.openAICompatible(baseURL: localURL, key: nil, model: model, idleUnload: Self.localIdleUnload, request)
        }
    }

    private static func describeLocal(_ error: Error, model: String) -> String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        switch error {
        case CloudError.http(400, let body) where body.contains("Failed to load model"):
            return "LM Studio doesn’t have the memory to load \(name), even with other models closed."
        case CloudError.http(let code, _):
            return "LM Studio answered \(code)."
        case let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost:
            return "LM Studio isn’t running, or its server is off."
        case let error as URLError where error.code == .timedOut:
            return "\(name) took too long to answer."
        default:
            return "\(name) didn’t give usable drafts."
        }
    }

    private var consentTasks: [String: Task<Bool, Never>] = [:]
    private var consentQueue: Task<Void, Never>?
    private var declined: Set<String> = []

    /// Several jobs can need the same consent at once; they share one prompt, and prompts
    /// for different conversations wait their turn. A "no" holds until the app quits.
    private func consent(_ key: String, title: String, provider: Provider) async -> Bool {
        if consents.contains(key) { return true }
        if declined.contains(key) { return false }
        if let pending = consentTasks[key] { return await pending.value }
        let previous = consentQueue
        let task = Task { [weak self] () -> Bool in
            await previous?.value
            guard let self else { return false }
            if consents.contains(key) { return true }
            let allowed = await askConsent(title: title, provider: provider)
            if allowed {
                consents.insert(key)
                defaults.set(Array(consents), forKey: Key.consents)
            } else {
                declined.insert(key)
            }
            return allowed
        }
        consentTasks[key] = task
        consentQueue = Task { _ = await task.value }
        let allowed = await task.value
        consentTasks[key] = nil
        return allowed
    }

    func forgetConsents() {
        consents = []
        declined = []
        defaults.removeObject(forKey: Key.consents)
    }

    private func askConsent(title: String, provider: Provider) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingConsent = ConsentRequest(conversation: title, provider: provider) { [weak self] allowed in
                self?.pendingConsent = nil
                continuation.resume(returning: allowed)
            }
        }
    }

    private func record(_ usage: Usage, route: Route) {
        let tokenKey = "\(Self.month)|\(route.provider.rawValue)"
        tokens[tokenKey, default: 0] += usage.input + usage.output
        defaults.set(tokens, forKey: Key.tokens)
        if route.provider == .anthropic, let price = CloudClient.anthropicPrices[route.model] {
            spend[Self.month, default: 0] += Double(usage.input) / 1_000_000 * price.input + Double(usage.output) / 1_000_000 * price.output
            defaults.set(spend, forKey: Key.spend)
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CloudError.http(401, _), CloudError.http(403, _): "The key was rejected."
        case CloudError.http(let code, _): "The server answered \(code)."
        case let error as URLError where error.code == .cannotConnectToHost: "Couldn’t reach the server. Is it running?"
        default: "Couldn’t verify: \(error.localizedDescription)"
        }
    }
}

enum LMStudio {
    static func unloadAll() {
        let lms = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lmstudio/bin/lms")
        guard FileManager.default.isExecutableFile(atPath: lms.path) else { return }
        let process = Process()
        process.executableURL = lms
        process.arguments = ["unload", "--all"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
