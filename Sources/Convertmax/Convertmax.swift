import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#endif

public enum ConvertmaxConsent: String, Codable, Sendable { case unknown, granted, denied }
public enum ConvertmaxEventType: String, Codable, Sendable { case track, identify, screen }

public struct ConvertmaxConfiguration: Sendable {
    public let writeKey: String
    public let appID: String
    public let environment: String
    public let endpoint: URL
    public let storageDirectory: URL?
    public let sessionTimeout: TimeInterval
    public let flushInterval: TimeInterval

    public init(writeKey: String, appID: String, environment: String = "production",
                endpoint: URL = URL(string: "https://event.convertmax.io/v1/batch")!,
                storageDirectory: URL? = nil, sessionTimeout: TimeInterval = 1800, flushInterval: TimeInterval = 30) {
        self.writeKey = writeKey; self.appID = appID; self.environment = environment
        self.endpoint = endpoint; self.storageDirectory = storageDirectory
        self.sessionTimeout = max(1, sessionTimeout); self.flushInterval = max(0, flushInterval)
    }
}

public struct ConvertmaxEvent: Codable, Sendable {
    public let messageId: UUID
    public let type: ConvertmaxEventType
    public let event: String?
    public let name: String?
    public let timestamp: Date
    public let anonymousId: String
    public let userId: String?
    public let properties: [String: String]?
    public let context: [String: String]
}

public struct ConvertmaxDiagnostics: Sendable, Equatable {
    public let queued: Int
    public let dropped: Int
    public init(queued: Int, dropped: Int) { self.queued = queued; self.dropped = dropped }
}

public struct ConvertmaxDeliveryResult: Sendable, Equatable {
    public let delivered: Int
    public let rejected: Int
    public let retained: Int
    public let attempts: Int
    public init(delivered: Int, retained: Int, attempts: Int, rejected: Int = 0) {
        self.rejected = rejected; self.delivered = delivered; self.retained = retained; self.attempts = attempts
    }
}

enum MobileV1Ack {
    struct Body: Decodable {
        let contract: String
        let results: [Item]
        struct Item: Decodable {
            let messageId: String
            let status: String
            let retryable: Bool?
        }
    }

    static func droppableMessageIds(httpStatus: Int, body: Data) -> Set<String>? {
        guard (200..<300).contains(httpStatus),
              let ack = try? JSONDecoder().decode(Body.self, from: body),
              ack.contract.lowercased() == "mobile-v1" else { return nil }
        return Set(ack.results.compactMap { item in
            if item.status == "accepted" { return item.messageId.lowercased() }
            if item.status == "rejected", item.retryable != true { return item.messageId.lowercased() }
            return nil
        })
    }
}

/// Enqueue-first API.
public actor Convertmax {
    public private(set) var consent: ConvertmaxConsent = .unknown
    private let configuration: ConvertmaxConfiguration
    private var anonymousId = UUID().uuidString
    private var userId: String?
    private var queue: [ConvertmaxEvent] = []
    private var dropped = 0
    private let store: EventStore
    public static let version = "0.2.0"
    private var lifecycleObserver: NSObjectProtocol?
    private var timer: Task<Void, Never>?
    private var uploadTask: Task<(Data, URLResponse), Error>?
    private var flushing = false
    private var generation = 0
    private var sessionId = UUID().uuidString
    private var lastActivity = Date.distantPast
    private var lastError: String?

    struct State: Codable {
        var consent: ConvertmaxConsent
        var anonymousId: String
        var userId: String?
        var sessionId: String
        var lastActivity: Date
    }

    public init(configuration: ConvertmaxConfiguration) {
        self.configuration = configuration
        let directory = configuration.storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Convertmax", isDirectory: true)
        let scope = SHA256.hash(data: Data("\(configuration.endpoint)|\(configuration.writeKey)|\(configuration.appID)|\(configuration.environment)".utf8)).map { String(format: "%02x", $0) }.joined()
        self.store = EventStore(directory: directory.appendingPathComponent(scope, isDirectory: true))
        if let state = store.loadState() {
            consent = state.consent; anonymousId = state.anonymousId; userId = state.userId
            sessionId = state.sessionId; lastActivity = state.lastActivity
        }
        self.queue = consent == .granted ? store.load() : []
        if consent != .granted { store.save([]) }
        Task { await self.installLifecycleAdapter() }
    }

    deinit {
        timer?.cancel(); uploadTask?.cancel()
        if let lifecycleObserver { NotificationCenter.default.removeObserver(lifecycleObserver) }
    }

    public func setConsent(_ value: ConvertmaxConsent) {
        consent = value
        if value != .granted {
            generation += 1; uploadTask?.cancel(); queue.removeAll()
            anonymousId = UUID().uuidString; userId = nil; sessionId = UUID().uuidString; lastActivity = .distantPast
        }
        persist()
    }

    @discardableResult public func identify(_ id: String) -> ConvertmaxEvent? {
        guard consent == .granted, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let previous = userId, previous != id { reset() }
        userId = id
        return enqueue(make(type: .identify, event: nil, name: nil, properties: [:]))
    }
    public func reset() {
        userId = nil; anonymousId = UUID().uuidString; sessionId = UUID().uuidString; lastActivity = .distantPast; persist()
    }

    public func track(_ name: String, properties: [String: String] = [:]) -> ConvertmaxEvent? {
        guard consent == .granted, !name.isEmpty else { return nil }
        return enqueue(make(type: .track, event: name, name: nil, properties: properties))
    }

    public func screen(_ name: String, properties: [String: String] = [:]) -> ConvertmaxEvent? {
        guard consent == .granted, !name.isEmpty else { return nil }
        return enqueue(make(type: .screen, event: nil, name: name, properties: properties))
    }

    public func revenue(transactionReference: String, amount: String? = nil, currency: String? = nil) -> ConvertmaxEvent? {
        guard !transactionReference.isEmpty else { return nil }
        var values = ["transactionReference": transactionReference]
        if let amount { values["amount"] = amount }
        if let currency { values["currency"] = currency }
        return track("purchase_observed", properties: values)
    }

    @discardableResult public func handleDeepLink(_ url: URL) -> [String: String] {
        let allowed = Set(["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "referrer"])
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            if let value = item.value, allowed.contains(item.name), value.count <= 256 { result[item.name] = value }
        }
    }

    /// Explicitly discards pending events. Does not change identity or consent.
    public func clearQueue() { generation += 1; uploadTask?.cancel(); queue.removeAll(); persist() }
    public func flush() async -> ConvertmaxDeliveryResult { await flushToNetwork() }
    public func flushToNetwork(maxAttempts: Int = 3) async -> ConvertmaxDeliveryResult {
        guard consent == .granted, !flushing else { return .init(delivered: 0, retained: queue.count, attempts: 0) }
        flushing = true
        defer { flushing = false; uploadTask = nil }
        let epoch = generation
        var attempts = 0, delivered = 0, rejected = 0, failures = 0
        // Bound this call to the queue present at entry; newly queued events wait for the next flush.
        let pending = Set(queue.map(\.messageId))
        while consent == .granted, generation == epoch, failures < max(1, maxAttempts) {
            let batch = Array(queue.filter { pending.contains($0.messageId) }.prefix(50))
            if batch.isEmpty { break }
            attempts += 1
            var delay: Double = min(30, pow(2, Double(failures))) + Double.random(in: 0...0.25)
            do {
                var builder = URLRequest(url: configuration.endpoint, timeoutInterval: 15)
                builder.httpMethod = "POST"
                builder.setValue("Bearer \(configuration.writeKey)", forHTTPHeaderField: "Authorization")
                builder.setValue("mobile-v1", forHTTPHeaderField: "X-Convertmax-Contract")
                builder.setValue("application/json", forHTTPHeaderField: "Content-Type")
                builder.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                builder.httpBody = Gzip.compress(try encoder.encode(BatchEnvelope(events: batch)))
                let request = builder
                let task = Task { try await URLSession.shared.data(for: request) }
                uploadTask = task
                let (data, response) = try await task.value
                guard generation == epoch, consent == .granted else { break }
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) { delay = min(60, max(0, seconds)) }
                if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 413 {
                    lastError = "HTTP \(http.statusCode): check configuration or event size"; break
                }
                guard let drop = MobileV1Ack.droppableMessageIds(httpStatus: http.statusCode, body: data),
                      let ack = try? JSONDecoder().decode(MobileV1Ack.Body.self, from: data) else { throw URLError(.badServerResponse) }
                let ids = Set(batch.map { $0.messageId.uuidString.lowercased() })
                let accepted = Set(ack.results.filter { $0.status == "accepted" }.map { $0.messageId.lowercased() }).intersection(ids)
                let remove = drop.intersection(ids)
                delivered += accepted.count; rejected += remove.subtracting(accepted).count
                queue.removeAll { remove.contains($0.messageId.uuidString.lowercased()) }
                persist()
                if remove.count == batch.count { failures = 0; lastError = nil; continue }
                lastError = "Retryable or incomplete acknowledgement"
            } catch { lastError = String(describing: error) }
            failures += 1
            if failures < max(1, maxAttempts), generation == epoch, consent == .granted {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        return .init(delivered: delivered, retained: queue.count, attempts: attempts, rejected: rejected)
    }
    public func deliveryError() -> String? { lastError }
    public func flushOnBackground() async { _ = await flushToNetwork() }
    public func diagnostics() -> ConvertmaxDiagnostics { ConvertmaxDiagnostics(queued: queue.count, dropped: dropped) }

    private func enqueue(_ event: ConvertmaxEvent) -> ConvertmaxEvent? {
        guard queue.count < 1000, (try? JSONEncoder().encode(event).count).map({ $0 <= 16384 }) == true else { dropped += 1; return nil }
        queue.append(event); persist(); return event
    }

    private func persist() {
        store.save(queue, state: State(consent: consent, anonymousId: anonymousId, userId: userId, sessionId: sessionId, lastActivity: lastActivity))
    }

    private func installLifecycleAdapter() {
        if configuration.flushInterval > 0 {
            let interval = configuration.flushInterval
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) } catch { break }
                    _ = await self?.flushToNetwork()
                }
            }
        }
        #if os(iOS)
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                let task = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "convertmax.flush") {} }
                _ = await self.flushOnBackground()
                await MainActor.run { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
            }
        }
        #endif
    }

    private struct BatchEnvelope: Encodable { let events: [ConvertmaxEvent] }

    private func make(type: ConvertmaxEventType, event: String?, name: String?, properties: [String: String]) -> ConvertmaxEvent {
        let now = Date()
        if now.timeIntervalSince(lastActivity) >= configuration.sessionTimeout { sessionId = UUID().uuidString }
        lastActivity = now
        var context = ["appId": configuration.appID, "environment": configuration.environment,
                       "sessionId": sessionId, "sdkVersion": Self.version, "sdkName": "convertmax-swift",
                       "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                       "locale": Locale.current.identifier, "timezone": TimeZone.current.identifier,
                       "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                       "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""]
        #if os(iOS)
        context["platform"] = "ios"
        #else
        context["platform"] = "macos"
        #endif
        return ConvertmaxEvent(messageId: UUID(), type: type, event: event, name: name, timestamp: Date(), anonymousId: anonymousId,
                        userId: userId, properties: properties, context: context)
    }
}
