import Foundation

public struct TailscaleStatus: Equatable {
    public let backendState: String?
    public let active: Bool
    public let serviceAttached: Bool
    public let hasOwnedRoutes: Bool

    public init(
        backendState: String?,
        active: Bool,
        serviceAttached: Bool,
        hasOwnedRoutes: Bool
    ) {
        self.backendState = backendState
        self.active = active
        self.serviceAttached = serviceAttached
        self.hasOwnedRoutes = hasOwnedRoutes
    }

    public var isSafelyStopped: Bool {
        backendState?.localizedCaseInsensitiveCompare("Stopped") == .orderedSame
            && !active
            && !hasOwnedRoutes
    }

    public var isEffectivelyActive: Bool {
        if isSafelyStopped {
            return false
        }
        if active || hasOwnedRoutes {
            return true
        }
        if backendState?.localizedCaseInsensitiveCompare("Running") == .orderedSame {
            return true
        }
        return backendState == nil && serviceAttached
    }

    public var isInertServiceAttached: Bool {
        isSafelyStopped && serviceAttached
    }
}

public enum HillstoneConnectionState: String, Equatable {
    case connected
    case disconnected
    case unknown
}

public func parseHillstoneConnectionState(_ logText: String) -> HillstoneConnectionState {
    for line in logText.split(separator: "\n").reversed() {
        if line.localizedCaseInsensitiveContains("Stop connect profile")
            || line.localizedCaseInsensitiveContains("will disconnect")
            || line.localizedCaseInsensitiveContains("Client will disconnect") {
            return .disconnected
        }
        if line.localizedCaseInsensitiveContains("Start connect profile") {
            return .connected
        }
    }
    return .unknown
}

public func redactedStateSummary(
    runningClients: [String],
    effectiveVPNs: [String],
    proxyCount: Int,
    hasUtunRoutes: Bool,
    v2Protected: Bool
) -> String {
    let clients = runningClients.isEmpty ? "无" : runningClients.joined(separator: ",")
    let vpns = effectiveVPNs.isEmpty ? "无" : effectiveVPNs.joined(separator: ",")
    return "客户端=\(clients); 有效VPN=\(vpns); 代理残留=\(proxyCount); utun=\(hasUtunRoutes ? "有" : "无"); v2保护=\(v2Protected ? "是" : "否")"
}

public func redactSensitiveText(_ text: String, homeDirectory: String) -> String {
    var value = text.replacingOccurrences(of: homeDirectory, with: "~")
    let patterns = [
        #"(?i)\b[a-z][a-z0-9+.-]*://\S+"#,
        #"\[[0-9A-Fa-f:]*:[0-9A-Fa-f:]+\]"#,
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
        #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "[已脱敏]")
    }
    return value
}
