import Foundation
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

    public init(writeKey: String, appID: String, environment: String = "production",
                endpoint: URL = URL(string: "https://event.convertmax.io/v1/batch")!,
                storageDirectory: URL? = nil) {
        self.writeKey = writeKey; self.appID = appID; self.environment = environment
        self.endpoint = endpoint; self.storageDirectory = storageDirectory
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
    public let retained: Int
    public let attempts: Int
    public init(delivered: Int, retained: Int, attempts: Int) {
        self.delivered = delivered; self.retained = retained; self.attempts = attempts
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
    private var lifecycleObserver: NSObjectProtocol?

    public init(configuration: ConvertmaxConfiguration) {
        self.configuration = configuration
        let directory = configuration.storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Convertmax", isDirectory: true)
        self.store = EventStore(directory: directory)
        self.queue = store.load()
        Task { await self.installLifecycleAdapter() }
    }

    deinit {
        if let lifecycleObserver { NotificationCenter.default.removeObserver(lifecycleObserver) }
    }

    public func setConsent(_ value: ConvertmaxConsent) {
        consent = value
        if value != .granted { anonymousId = UUID().uuidString; userId = nil }
    }

    public func identify(_ id: String) { guard consent == .granted, !id.isEmpty else { return }; userId = id }
    public func reset() { userId = nil; anonymousId = UUID().uuidString }

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

    public func flush() -> [ConvertmaxEvent] { defer { queue.removeAll(); persist() }; return queue }
    public func flushToNetwork(maxAttempts: Int = 3) async -> ConvertmaxDeliveryResult {
        var attempts = 0
        var delivered = 0
        while attempts < max(1, maxAttempts) && !queue.isEmpty {
            attempts += 1
            let batch = Array(queue.prefix(50))
            do {
                var request = URLRequest(url: configuration.endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(configuration.writeKey)", forHTTPHeaderField: "Authorization")
                request.setValue("mobile-v1", forHTTPHeaderField: "X-Convertmax-Contract")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                request.httpBody = Gzip.compress(try JSONEncoder().encode(BatchEnvelope(events: batch)))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      let drop = MobileV1Ack.droppableMessageIds(httpStatus: http.statusCode, body: data) else {
                    throw URLError(.badServerResponse)
                }
                let before = queue.count
                queue.removeAll { drop.contains($0.messageId.uuidString.lowercased()) }
                delivered += max(0, before - queue.count)
                persist()
            } catch {
                if attempts < max(1, maxAttempts) { try? await Task.sleep(nanoseconds: UInt64(250_000_000 * attempts)) }
            }
        }
        return ConvertmaxDeliveryResult(delivered: delivered, retained: queue.count, attempts: attempts)
    }
    public func flushOnBackground() async { _ = await flushToNetwork() }
    public func diagnostics() -> ConvertmaxDiagnostics { ConvertmaxDiagnostics(queued: queue.count, dropped: dropped) }

    private func enqueue(_ event: ConvertmaxEvent) -> ConvertmaxEvent? {
        guard queue.count < 1000 else { dropped += 1; return nil }
        queue.append(event); persist(); return event
    }

    private func persist() { store.save(queue) }

    private func installLifecycleAdapter() {
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
        ConvertmaxEvent(messageId: UUID(), type: type, event: event, name: name, timestamp: Date(), anonymousId: anonymousId,
                        userId: userId, properties: properties, context: ["appId": configuration.appID, "environment": configuration.environment])
    }
}
