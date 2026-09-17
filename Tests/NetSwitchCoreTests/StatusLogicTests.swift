import Foundation
import Testing
@testable import NetSwitchCore

@Test func stoppedBackendWithAttachedServiceIsSafe() {
    let status = TailscaleStatus(
        backendState: "Stopped",
        active: false,
        serviceAttached: true,
        hasOwnedRoutes: false
    )

    #expect(status.isSafelyStopped)
    #expect(!status.isEffectivelyActive)
    #expect(status.isInertServiceAttached)
}

@Test func runningBackendIsActive() {
    let status = TailscaleStatus(
        backendState: "Running",
        active: true,
        serviceAttached: true,
        hasOwnedRoutes: false
    )

    #expect(status.isEffectivelyActive)
    #expect(!status.isSafelyStopped)
}

@Test func stoppedBackendWithOwnedRoutesRemainsActive() {
    let status = TailscaleStatus(
        backendState: "Stopped",
        active: false,
        serviceAttached: true,
        hasOwnedRoutes: true
    )

    #expect(status.isEffectivelyActive)
    #expect(!status.isSafelyStopped)
}

@Test func unavailableBackendUsesServiceAsConservativeFallback() {
    let status = TailscaleStatus(
        backendState: nil,
        active: false,
        serviceAttached: true,
        hasOwnedRoutes: false
    )

    #expect(status.isEffectivelyActive)
}

@Test func redactedSummaryContainsNoConnectionDetails() {
    let summary = redactedStateSummary(
        runningClients: ["v2rayN"],
        effectiveVPNs: [],
        proxyCount: 0,
        hasUtunRoutes: true,
        v2Protected: true
    )

    #expect(summary.contains("v2rayN"))
    #expect(summary.contains("v2保护=是"))
    #expect(!summary.contains("://"))
    #expect(!summary.contains("@"))
}

@Test func sensitiveDiagnosticTextIsRedacted() {
    let text = "demo://credential@example.invalid:443 contact@example.invalid /example/home/private [2409:8c02:248:101::d0]:443"
    let redacted = redactSensitiveText(text, homeDirectory: "/example/home")

    #expect(!redacted.contains("demo://"))
    #expect(!redacted.contains("contact@example.invalid"))
    #expect(!redacted.contains("/example/home"))
    #expect(!redacted.contains("2409:8c02"))
}

@Test func hillstoneLatestLifecycleEventWins() {
    let connected = """
    Start connect profile internal
    """
    let disconnected = """
    Start connect profile internal
    Profile [internal] will disconnect
    Stop connect profile internal
    """

    #expect(parseHillstoneConnectionState(connected) == .connected)
    #expect(parseHillstoneConnectionState(disconnected) == .disconnected)
    #expect(parseHillstoneConnectionState("Service is running") == .unknown)
}

@Test func tailscaleExitNodeDetailsAreParsed() throws {
    let status = """
    {"BackendState":"Running","Peer":{"node":{"HostName":"vps-2026","Online":true,"ExitNode":true,"Relay":"lax","CurAddr":""}}}
    """.data(using: .utf8)!
    let prefs = #"{"ExitNodeAllowLANAccess":true}"#.data(using: .utf8)!
    let parsed = parseTailscaleStatus(
        statusData: status,
        preferencesData: prefs,
        serviceAttached: true,
        hasOwnedRoutes: true
    )

    #expect(parsed?.exitNodeName == "vps-2026")
    #expect(parsed?.exitNodeOnline == true)
    #expect(parsed?.peerName == "vps-2026")
    #expect(parsed?.peerOnline == true)
    #expect(parsed?.connectionPath == .relay)
    #expect(parsed?.relayRegion == "lax")
    #expect(parsed?.exitNodeAllowLANAccess == true)
}

@Test func networkModesAreDistinct() {
    let mesh = TailscaleStatus(
        backendState: "Running", active: true, serviceAttached: true, hasOwnedRoutes: true
    )
    let exit = TailscaleStatus(
        backendState: "Running", active: true, serviceAttached: true, hasOwnedRoutes: true,
        exitNodeName: "vps-2026", exitNodeOnline: true
    )

    #expect(inferNetworkMode(tailscale: mesh, clashRunning: true, clashProxyActive: true, hasOtherNetworkOwner: false) == .split)
    #expect(inferNetworkMode(tailscale: exit, clashRunning: false, clashProxyActive: false, hasOtherNetworkOwner: false) == .fallback)
    #expect(inferNetworkMode(tailscale: mesh, clashRunning: false, clashProxyActive: false, hasOtherNetworkOwner: false) == .direct)
    #expect(inferNetworkMode(tailscale: exit, clashRunning: true, clashProxyActive: true, hasOtherNetworkOwner: false) == .conflict)
    let stopped = TailscaleStatus(backendState: "Stopped", active: false, serviceAttached: true, hasOwnedRoutes: false)
    #expect(inferNetworkMode(tailscale: stopped, clashRunning: false, clashProxyActive: false, hasOtherNetworkOwner: false) == .degraded)
    #expect(inferNetworkMode(tailscale: stopped, clashRunning: false, clashProxyActive: false, hasOtherNetworkOwner: true) == .standalone)
    #expect(inferNetworkMode(tailscale: mesh, clashRunning: false, clashProxyActive: false, hasOtherNetworkOwner: true) == .conflict)
}

@Test func clashLogWindowFiltersOldLines() {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026; components.month = 9; components.day = 16
    components.hour = 12; components.minute = 0; components.second = 0
    let now = components.date!

    #expect(logLineIsWithin("2026-09-16 11:30:00 WARN timeout", hours: 24, now: now))
    #expect(!logLineIsWithin("2026-09-12 18:39:22 WARN timeout", hours: 24, now: now))
    #expect(logLineIsWithin("09-16 11:59:00 WARNING failed", hours: 24, now: now))
    #expect(logLineIsWithin("[2026-09-16 11:59:00.123] level=warning timeout", hours: 24, now: now))
}
