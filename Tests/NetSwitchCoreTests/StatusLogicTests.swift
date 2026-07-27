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
    let text = "demo://credential@example.invalid:443 contact@example.invalid /example/home/private"
    let redacted = redactSensitiveText(text, homeDirectory: "/example/home")

    #expect(!redacted.contains("demo://"))
    #expect(!redacted.contains("contact@example.invalid"))
    #expect(!redacted.contains("/example/home"))
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
