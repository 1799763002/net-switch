import Foundation
import Testing
@testable import NetSwitchCore

@Test func curlProbeReportsTransportErrorsAndParsesTrailer() {
    let failed = parseCurlProbe(output: "curl: (28) Timeout\nNET_PROBE 000 10.002", status: 28)
    #expect(!failed.ok)
    #expect(failed.summary.contains("curl=28"))
    #expect(failed.summary.contains("Timeout"))
    #expect(parseCurlProbe(output: "warning text\nNET_PROBE 204 0.42", status: 0).ok)
    #expect(!parseCurlProbe(output: "NET_PROBE 204 0.42", status: 28).ok)
    #expect(!parseCurlProbe(output: "NET_PROBE 503 0.42", status: 0).ok)
    #expect(!parseCurlProbe(output: "", status: 0).ok)
}

@Test func rotatedClashLogsSurviveLaterLaunchAndAreDeduplicated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("sidecar"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let stamp = formatter.string(from: now.addingTimeInterval(-60))
    let old = formatter.string(from: now.addingTimeInterval(-26 * 3600))
    let route = "[\(stamp)] level=info msg=\"[TCP] using fallback[AnyTLS]\""
    let warning = "[\(stamp)] level=warning msg=\"timeout\""
    try "\(route)\n\(warning)\n[\(old)] level=error stale".write(to: directory.appendingPathComponent("sidecar/session.log"), atomically: true, encoding: .utf8)
    try warning.write(to: directory.appendingPathComponent("sidecar/sidecar_latest.log"), atomically: true, encoding: .utf8)
    try "[\(stamp)] INFO healthy startup".write(to: directory.appendingPathComponent("latest.log"), atomically: true, encoding: .utf8)
    let result = recentClashLogLines(directory: directory, limit: 80, now: now)
    #expect(result.count == 2)
    #expect(result.contains(route))
    #expect(result.contains(warning))
    #expect(recentClashLogLines(directory: directory, limit: 1, now: now).count == 1)
}
