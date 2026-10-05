import Foundation

public enum ClashLogCategory: Sendable {
    case exception
    case route
}

public func clashLogCategory(for line: String) -> ClashLogCategory? {
    let normalized = line.lowercased()
    let exceptionMarkers = ["level=error", "level=warning", "level=warn", " error ", " warn ",
                            "timeout", "deadline", "reset", "failed", "process terminated"]
    if exceptionMarkers.contains(where: { normalized.contains($0) }) {
        return .exception
    }
    if normalized.contains("[tcp]") || normalized.contains("[udp]") {
        return .route
    }
    return nil
}

public func hasConsecutiveSuccesses(_ samples: [Bool], required: Int = 2) -> Bool {
    guard required > 0 else { return true }
    var streak = 0
    for sample in samples {
        streak = sample ? streak + 1 : 0
        if streak >= required { return true }
    }
    return false
}

/// curl's stderr shares a pipe with stdout. Parse the explicit trailer, not the
/// first whitespace token (which can be a warning even on a successful request).
public func parseCurlProbe(output: String, status: Int32) -> (ok: Bool, summary: String) {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let trailer = lines.last { $0.hasPrefix("NET_PROBE ") }
    let fields = trailer?.split(separator: " ") ?? []
    let code = fields.count >= 3 ? Int(fields[1]) ?? 0 : 0
    let elapsed = fields.count >= 3 ? String(fields[2]) : "未知"
    let errors = lines.filter { !$0.hasPrefix("NET_PROBE ") }.joined(separator: " | ")
    let summary = "curl=\(status) HTTP=\(code) 耗时=\(elapsed)秒" + (errors.isEmpty ? "" : " 错误=\(errors.prefix(1200))")
    return (status == 0 && code >= 200 && code < 500, summary)
}

/// Read rotated sessions too: latest.log may belong to a later, healthy launch.
public func recentClashLogLines(
    directory: URL,
    category: ClashLogCategory,
    limit: Int,
    now: Date = Date()
) -> [String] {
    let manager = FileManager.default
    let files = [directory, directory.appendingPathComponent("sidecar")].flatMap { folder in
        (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }.filter { $0.pathExtension == "log" }
    var seen = Set<String>()
    var result: [String] = []
    for file in files.sorted(by: { $0.path < $1.path }) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard logLineIsWithin(line, hours: 24, now: now),
                  clashLogCategory(for: line) == category,
                  seen.insert(line).inserted else { continue }
            result.append(line)
        }
    }
    return Array(result.sorted().suffix(max(0, limit)))
}
