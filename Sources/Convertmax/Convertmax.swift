import Foundation

public enum ConvertmaxConsent: String, Codable, Sendable { case unknown, granted, denied }
public enum ConvertmaxEventType: String, Codable, Sendable { case track, identify, screen }

public struct ConvertmaxConfiguration: Sendable {
    public let writeKey: String
    public let appID: String
    public let environment: String
    public let endpoint: URL

    public init(writeKey: String, appID: String, environment: String = "production",
                endpoint: URL = URL(string: "https://event.convertmax.io/v1/batch")!) {
        self.writeKey = writeKey; self.appID = appID; self.environment = environment; self.endpoint = endpoint
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

/// A deliberately small, enqueue-first API. Networking and durable storage are added behind this stable surface.
public actor Convertmax {
    public private(set) var consent: ConvertmaxConsent = .unknown
    private let configuration: ConvertmaxConfiguration
    private var anonymousId = UUID().uuidString
    private var userId: String?
    private var queue: [ConvertmaxEvent] = []
    private var dropped = 0
    private let queueURL: URL

    public init(configuration: ConvertmaxConfiguration) {
        self.configuration = configuration
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent("Convertmax", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.queueURL = directory.appendingPathComponent("events.json")
        if let data = try? Data(contentsOf: queueURL), let stored = try? JSONDecoder().decode([ConvertmaxEvent].self, from: data) {
            self.queue = Array(stored.prefix(1000))
        }
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
                request.httpBody = try JSONEncoder().encode(BatchEnvelope(events: batch))
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                queue.removeFirst(batch.count); delivered += batch.count; persist()
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

    private func persist() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: queueURL, options: [.atomic])
    }

    private struct BatchEnvelope: Encodable { let events: [ConvertmaxEvent] }

    private func make(type: ConvertmaxEventType, event: String?, name: String?, properties: [String: String]) -> ConvertmaxEvent {
        ConvertmaxEvent(messageId: UUID(), type: type, event: event, name: name, timestamp: Date(), anonymousId: anonymousId,
                        userId: userId, properties: properties, context: ["appId": configuration.appID, "environment": configuration.environment])
    }
}
