import Foundation
import os

/// Append-only local log. No frames, no images — just decisions, so you can
/// audit false locks and calibrate thresholds without keeping video around.
struct SentryEvent: Codable {
    let at: Date
    let kind: String
    let detail: String
    let livenessScore: Double?
    let similarity: Float?
}

final class EventLog {
    static let shared = EventLog()

    private let logger = Logger(subsystem: "com.jacksonmafra.vakt", category: "sentry")
    private let url: URL
    private let queue = DispatchQueue(label: "vakt.log", qos: .utility)

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VAKT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        url = dir.appendingPathComponent("events.jsonl")
    }

    func record(_ kind: String,
                _ detail: String,
                liveness: Double? = nil,
                similarity: Float? = nil) {
        let event = SentryEvent(at: Date(), kind: kind, detail: detail,
                                livenessScore: liveness, similarity: similarity)
        logger.info("\(kind, privacy: .public): \(detail, privacy: .public)")
        queue.async { [url] in
            guard var line = try? JSONEncoder().encode(event) else { return }
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    func recent(limit: Int = 50) -> [SentryEvent] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").suffix(limit).compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? decoder.decode(SentryEvent.self, from: d)
        }
    }
}
