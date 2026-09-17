import Foundation

public struct TailscaleStatus: Equatable {
    public let backendState: String?
    public let active: Bool
    public let serviceAttached: Bool
    public let hasOwnedRoutes: Bool
    public let exitNodeName: String?
    public let exitNodeOnline: Bool?
    public let peerName: String?
    public let peerOnline: Bool?
    public let connectionPath: TailscaleConnectionPath
    public let relayRegion: String?
    public let exitNodeAllowLANAccess: Bool

    public init(
        backendState: String?,
        active: Bool,
        serviceAttached: Bool,
        hasOwnedRoutes: Bool,
        exitNodeName: String? = nil,
        exitNodeOnline: Bool? = nil,
        peerName: String? = nil,
        peerOnline: Bool? = nil,
        connectionPath: TailscaleConnectionPath = .unknown,
        relayRegion: String? = nil,
        exitNodeAllowLANAccess: Bool = false
    ) {
        self.backendState = backendState
        self.active = active
        self.serviceAttached = serviceAttached
        self.hasOwnedRoutes = hasOwnedRoutes
        self.exitNodeName = exitNodeName
        self.exitNodeOnline = exitNodeOnline
        self.peerName = peerName
        self.peerOnline = peerOnline
        self.connectionPath = connectionPath
        self.relayRegion = relayRegion
        self.exitNodeAllowLANAccess = exitNodeAllowLANAccess
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

    public var usingExitNode: Bool { exitNodeName != nil }
}

public enum TailscaleConnectionPath: String, Equatable {
    case direct
    case relay
    case unknown
}

public enum NetworkMode: String, Equatable {
    case fallback
    case split
    case direct
    case standalone
    case conflict
    case degraded

    public var chineseLabel: String {
        switch self {
        case .fallback: return "兜底"
        case .split: return "分流"
        case .direct: return "直连"
        case .standalone: return "单独客户端"
        case .conflict: return "冲突"
        case .degraded: return "降级"
        }
    }
}

public func inferNetworkMode(
    tailscale: TailscaleStatus,
    clashRunning: Bool,
    clashProxyActive: Bool,
    hasOtherNetworkOwner: Bool
) -> NetworkMode {
    if hasOtherNetworkOwner {
        if tailscale.isEffectivelyActive || clashRunning || clashProxyActive {
            return .conflict
        }
        return .standalone
    }
    if tailscale.usingExitNode && (clashRunning || clashProxyActive) {
        return .conflict
    }
    if tailscale.usingExitNode {
        return tailscale.exitNodeOnline == false ? .degraded : .fallback
    }
    if clashRunning && clashProxyActive {
        return tailscale.isEffectivelyActive ? .split : .degraded
    }
    if clashRunning != clashProxyActive { return .degraded }
    return tailscale.isEffectivelyActive ? .direct : .degraded
}

public func parseTailscaleStatus(
    statusData: Data,
    preferencesData: Data?,
    serviceAttached: Bool,
    hasOwnedRoutes: Bool
) -> TailscaleStatus? {
    guard let object = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else {
        return nil
    }
    let preferences = preferencesData.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let peers = object["Peer"] as? [String: Any] ?? [:]
    let decodedPeers = peers.values.compactMap { $0 as? [String: Any] }
    let selected = decodedPeers.first {
        ($0["ExitNode"] as? Bool) == true
    }
    let preferredPeer = selected ?? decodedPeers.first {
        ($0["HostName"] as? String)?.localizedCaseInsensitiveCompare("vps-2026") == .orderedSame
    } ?? decodedPeers.first {
        ($0["ExitNodeOption"] as? Bool) == true
    }
    let name = selected?["HostName"] as? String
        ?? (selected?["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let peerName = preferredPeer?["HostName"] as? String
        ?? (preferredPeer?["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let currentAddress = preferredPeer?["CurAddr"] as? String ?? ""
    let relay = preferredPeer?["Relay"] as? String
    let path: TailscaleConnectionPath
    if preferredPeer == nil {
        path = .unknown
    } else if !currentAddress.isEmpty {
        path = .direct
    } else if let relay, !relay.isEmpty {
        path = .relay
    } else {
        path = .unknown
    }
    return TailscaleStatus(
        backendState: object["BackendState"] as? String,
        active: object["Active"] as? Bool ?? false,
        serviceAttached: serviceAttached,
        hasOwnedRoutes: hasOwnedRoutes,
        exitNodeName: name,
        exitNodeOnline: selected?["Online"] as? Bool,
        peerName: peerName,
        peerOnline: preferredPeer?["Online"] as? Bool,
        connectionPath: path,
        relayRegion: relay,
        exitNodeAllowLANAccess: preferences?["ExitNodeAllowLANAccess"] as? Bool ?? false
    )
}

public func logLineIsWithin(_ line: String, hours: TimeInterval, now: Date = Date()) -> Bool {
    let candidate = line.hasPrefix("[") ? String(line.dropFirst()) : line
    let prefixes = [
        (#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z"#, "yyyy-MM-dd'T'HH:mm:ssXXXXX"),
        (#"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, "yyyy-MM-dd HH:mm:ss")
    ]
    for (pattern, format) in prefixes {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              let range = Range(match.range, in: candidate) else { continue }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = format.contains("XXXXX") ? TimeZone(secondsFromGMT: 0) : .current
        formatter.dateFormat = format
        var value = String(candidate[range])
        if format.contains("XXXXX"), let dot = value.firstIndex(of: "."), let z = value.lastIndex(of: "Z") {
            value.removeSubrange(dot..<z)
        }
        if let date = formatter.date(from: value), now.timeIntervalSince(date) >= 0,
           now.timeIntervalSince(date) <= hours * 3600 { return true }
    }
    let shortPattern = #"^(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})"#
    if let regex = try? NSRegularExpression(pattern: shortPattern),
       let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year], from: now)
        let values = (1...5).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: candidate) else { return nil }
            return Int(candidate[range])
        }
        if values.count == 5 {
            components.month = values[0]; components.day = values[1]
            components.hour = values[2]; components.minute = values[3]; components.second = values[4]
            if let date = calendar.date(from: components), now.timeIntervalSince(date) >= 0,
               now.timeIntervalSince(date) <= hours * 3600 { return true }
        }
    }
    return false
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
