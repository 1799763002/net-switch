import Foundation
import NetSwitchCore
import Darwin

final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum Shell {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        timeout: TimeInterval = 3
    ) -> (output: String, status: Int32) {
        let process = Process()
        let pipe = Pipe()
        let output = CommandOutputBuffer()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { output.append(chunk) }
        }
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            // Process keeps the parent's copy of the pipe writer open. Closing it here
            // guarantees readDataToEndOfFile can observe EOF after the child exits.
            try? pipe.fileHandleForWriting.close()
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 0.5) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + 0.5)
                }
                pipe.fileHandleForReading.readabilityHandler = nil
                return (output.string() + "Command timed out after \(timeout) seconds\n", 124)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            output.append(pipe.fileHandleForReading.readDataToEndOfFile())
            return (output.string(), process.terminationStatus)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ("Unable to run \(executable): \(error.localizedDescription)", 127)
        }
    }
}

enum ANSI {
    static let reset = "\u{001B}[0m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"
    static let bold = "\u{001B}[1m"

    static func paint(_ text: String, _ color: String) -> String { "\(color)\(text)\(reset)" }
}

enum Client: String, CaseIterable {
    case v2rayn, bywave, clash, powervpn, viscosity, hillstone, tailscale

    var title: String {
        switch self {
        case .v2rayn: return "v2rayN"
        case .bywave: return "ByWave"
        case .clash: return "Clash Verge"
        case .powervpn: return "PowerVPN"
        case .viscosity: return "Viscosity"
        case .hillstone: return "Hillstone Secure Connect"
        case .tailscale: return "Tailscale"
        }
    }

    var bundleID: String {
        switch self {
        case .v2rayn: return "2dust.v2rayN"
        case .bywave: return "com.bywave.client"
        case .clash: return "io.github.clash-verge-rev.clash-verge-rev"
        case .powervpn: return "com.leadsec.PowerVPN-Mac"
        case .viscosity: return "com.viscosityvpn.Viscosity"
        case .hillstone: return "com.hillstonenet.secureconnect"
        case .tailscale: return "io.tailscale.ipn.macsys"
        }
    }

    var appName: String {
        switch self {
        case .v2rayn: return "v2rayN"
        case .bywave: return "ByWave"
        case .clash: return "Clash Verge"
        case .powervpn: return "PowerVPN"
        case .viscosity: return "Viscosity"
        case .hillstone: return "Hillstone Secure Connect"
        case .tailscale: return "Tailscale"
        }
    }

    var processNeedles: [String] {
        switch self {
        case .v2rayn: return ["/v2rayN.app/", "/Application Support/v2rayN/bin/"]
        case .bywave: return ["/ByWave.app/Contents/MacOS/bywave", "/ByWave.app/Contents/MacOS/mihomo"]
        case .clash: return ["/Clash Verge.app/", "verge-mihomo"]
        case .powervpn: return ["/PowerVPN.app/"]
        case .viscosity: return ["/Viscosity.app/"]
        case .hillstone: return ["/Hillstone Secure Connect.app/Contents/MacOS/HillstoneSecureConnect"]
        case .tailscale: return ["/Tailscale.app/", "tailscaled"]
        }
    }

    var proxyPort: Int? {
        switch self {
        case .v2rayn: return 10808
        case .bywave: return 7893
        case .clash: return 7897
        default: return nil
        }
    }
}

let managedLocalProxyPorts = Set(Client.allCases.compactMap(\.proxyPort))
let splitVPSAddress = "100.110.219.72"
let splitVPSName = "vps-2026"
let clashProxyPort = 7897

func isShellCommandLine(_ line: String) -> Bool {
    let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let shellPrefixes = ["/bin/sh ", "/bin/zsh ", "/bin/bash ", "/usr/bin/env "]
    return shellPrefixes.contains(where: { command.hasPrefix($0) })
}

func matchesClientProcess(_ line: String, client: Client) -> Bool {
    let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if isShellCommandLine(command) { return false }
    if client == .hillstone {
        return client.processNeedles.contains {
            command.localizedCaseInsensitiveContains($0)
                && !command.localizedCaseInsensitiveContains("HillstoneSecureConnectService")
        }
    }
    return client.processNeedles.contains { command.localizedCaseInsensitiveContains($0) }
}

struct ProxyEntry: Equatable {
    let service: String
    let type: String
    let host: String
    let port: Int
}

struct Snapshot {
    let processLines: [String]
    let proxyEntries: [ProxyEntry]
    let connectedVPNs: [String]
    let utunRouteLines: [String]
    let viscosityStates: [String]
    let tailscaleStatus: TailscaleStatus
    let hillstoneConnectionState: HillstoneConnectionState
    let hillstoneServiceRunning: Bool
    let byWaveHelperRunning: Bool
    let byWaveTunEnabled: Bool
    let otherNetSwitchProcesses: [String]

    func isRunning(_ client: Client) -> Bool {
        processLines.contains { matchesClientProcess($0, client: client) }
    }

    func proxyIsActive(_ client: Client) -> Bool {
        guard let port = client.proxyPort else { return false }
        return proxyEntries.contains { $0.port == port && isLocalHost($0.host) }
    }

    var hasActivity: Bool {
        let nonTailscaleProcess = Client.allCases
            .filter { $0 != .tailscale }
            .contains { isRunning($0) }
        let effectiveVPN = connectedVPNs.contains { !$0.localizedCaseInsensitiveContains("Tailscale") }
            || tailscaleStatus.usingExitNode
        return nonTailscaleProcess
            || effectiveVPN
            || hillstoneConnectionState == .connected
            || hasActiveViscosityConnection
    }

    var hasOtherNetworkOwner: Bool {
        Client.allCases.filter { $0 != .tailscale && $0 != .clash }.contains { isRunning($0) }
            || connectedVPNs.contains { !$0.localizedCaseInsensitiveContains("Tailscale") }
            || hasActiveViscosityConnection
            || hillstoneConnectionState == .connected
    }

    var networkMode: NetworkMode {
        inferNetworkMode(
            tailscale: tailscaleStatus,
            clashRunning: isRunning(.clash),
            clashProxyActive: effectiveSystemProxyUses(port: clashProxyPort),
            hasOtherNetworkOwner: hasOtherNetworkOwner
        )
    }

    var v2Protected: Bool {
        isRunning(.v2rayn) && !utunRouteLines.isEmpty
    }

    var hasActiveViscosityConnection: Bool {
        viscosityStates.contains {
            !$0.localizedCaseInsensitiveContains("disconnected")
                && !$0.localizedCaseInsensitiveContains("automation unavailable")
        }
    }

    var runningClientNames: [String] {
        Client.allCases.filter { isRunning($0) }.map(\.title)
    }

    var effectiveVPNNames: [String] {
        var names = connectedVPNs.compactMap { line -> String? in
            if line.localizedCaseInsensitiveContains("Tailscale") { return nil }
            if line.contains("小地球仪") { return "PowerVPN" }
            return "其他VPN"
        }
        if tailscaleStatus.isEffectivelyActive { names.append("Tailscale") }
        if hasActiveViscosityConnection { names.append("Viscosity") }
        if hillstoneConnectionState == .connected { names.append("Hillstone") }
        return Array(Set(names)).sorted()
    }
}

func isLocalHost(_ host: String) -> Bool {
    ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
}

func proxyOwner(for entry: ProxyEntry) -> Client? {
    Client.allCases.first { $0.proxyPort == entry.port }
}

func byWaveTunIsEnabled() -> Bool {
    let result = Shell.run("/usr/bin/curl", [
        "-fsS", "--max-time", "1", "http://127.0.0.1:9090/configs"
    ])
    guard result.status == 0,
          let data = result.output.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tun = object["tun"] as? [String: Any],
          let enabled = tun["enable"] as? Bool else { return false }
    return enabled
}

func disableByWaveTun() -> Bool {
    let result = Shell.run("/usr/bin/curl", [
        "-fsS", "--max-time", "3", "-X", "PATCH",
        "-H", "Content-Type: application/json",
        "--data", "{\"tun\":{\"enable\":false}}",
        "http://127.0.0.1:9090/configs"
    ])
    return result.status == 0
}

func confirmYesNo(_ prompt: String) -> Bool {
    print("\(prompt) [y/N]: ", terminator: "")
    guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
    }
    return answer == "y" || answer == "yes"
}

func commandLines(_ executable: String, _ arguments: [String]) -> [String] {
    Shell.run(executable, arguments).output
        .split(separator: "\n")
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

func networkServices() -> [String] {
    commandLines("/usr/sbin/networksetup", ["-listallnetworkservices"])
        .dropFirst()
        .map { $0.hasPrefix("*") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }
}

func parseProxy(_ text: String, service: String, type: String) -> ProxyEntry? {
    var enabled = false
    var host = ""
    var port: Int?
    for line in text.split(separator: "\n").map(String.init) {
        let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "Enabled": enabled = parts[1].lowercased() == "yes"
        case "Server": host = parts[1]
        case "Port": port = Int(parts[1])
        default: break
        }
    }
    guard enabled, let port else { return nil }
    return ProxyEntry(service: service, type: type, host: host, port: port)
}

func currentProxyEntries() -> [ProxyEntry] {
    var entries: [ProxyEntry] = []
    for service in networkServices() {
        let requests: [(String, String)] = [
            ("HTTP", "-getwebproxy"),
            ("HTTPS", "-getsecurewebproxy"),
            ("SOCKS", "-getsocksfirewallproxy")
        ]
        for (type, command) in requests {
            let result = Shell.run("/usr/sbin/networksetup", [command, service])
            if let entry = parseProxy(result.output, service: service, type: type) {
                entries.append(entry)
            }
        }
    }
    return entries
}

func connectedVPNs() -> [String] {
    commandLines("/usr/sbin/scutil", ["--nc", "list"])
        .filter { $0.contains("(Connected)") || $0.contains("(Connecting)") || $0.contains("(Disconnecting)") }
}

func viscosityStates(isRunning: Bool) -> [String] {
    guard isRunning else { return [] }
    let script = """
    tell application id "com.viscosityvpn.Viscosity"
      set outputLines to {}
      repeat with itemConnection in connections
        set end of outputLines to (name of itemConnection) & " | " & (state of itemConnection)
      end repeat
      return outputLines as text
    end tell
    """
    let result = Shell.run("/usr/bin/osascript", ["-e", script])
    guard result.status == 0 else { return ["Viscosity automation unavailable"] }
    return result.output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

func tailscaleCLIStatus(serviceAttached: Bool, routeLines: [String]) -> TailscaleStatus {
    let result = Shell.run("/usr/local/bin/tailscale", ["status", "--json"], timeout: 2)
    let preferences = Shell.run("/usr/local/bin/tailscale", ["debug", "prefs"], timeout: 2)
    guard result.status == 0,
          let data = result.output.data(using: .utf8),
          let parsed = parseTailscaleStatus(
            statusData: data,
            preferencesData: preferences.status == 0 ? preferences.output.data(using: .utf8) : nil,
            serviceAttached: serviceAttached,
            hasOwnedRoutes: hasTailscaleOwnedRoutes(routeLines)
          ) else {
        return TailscaleStatus(
            backendState: nil,
            active: false,
            serviceAttached: serviceAttached,
            hasOwnedRoutes: hasTailscaleOwnedRoutes(routeLines)
        )
    }
    return parsed
}

func hasTailscaleOwnedRoutes(_ routeLines: [String]) -> Bool {
    routeLines.contains { line in
        let destination = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return destination == "100.64/10"
            || destination == "100.100.100.100"
            || destination.hasPrefix("100.64.")
    }
}

func hillstoneConnectionState() -> HillstoneConnectionState {
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HillstoneSecureConnect/log/uisecureconnect.log")
    guard let handle = try? FileHandle(forReadingFrom: file) else { return .unknown }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let maximumBytes: UInt64 = 2 * 1_024 * 1_024
    try? handle.seek(toOffset: size > maximumBytes ? size - maximumBytes : 0)
    guard let data = try? handle.readToEnd(),
          let text = String(data: data, encoding: .utf8) else { return .unknown }
    return parseHillstoneConnectionState(text)
}

func hillstoneStateLabel(_ state: HillstoneConnectionState) -> String {
    switch state {
    case .connected: return "已连接"
    case .disconnected: return "已断开"
    case .unknown: return "无法确认"
    }
}

func takeSnapshot() -> Snapshot {
    let allProcessRows = commandLines("/bin/ps", ["ax", "-o", "pid=,command="])
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let allProcesses = allProcessRows.compactMap { row -> String? in
        let parts = row.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, Int32(parts[0]) != ownPID else { return nil }
        return String(parts[1])
    }
    let selected = allProcesses.filter { line in
        Client.allCases.contains { matchesClientProcess(line, client: $0) }
    }
    let routes = commandLines("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        .filter { $0.contains("utun") }
    let vpnLines = connectedVPNs()
    let tailscaleAttached = vpnLines.contains { $0.localizedCaseInsensitiveContains("Tailscale") }
    let viscosityRunning = selected.contains { $0.localizedCaseInsensitiveContains("/Viscosity.app/") }
    return Snapshot(
        processLines: selected,
        proxyEntries: currentProxyEntries(),
        connectedVPNs: vpnLines,
        utunRouteLines: routes,
        viscosityStates: viscosityStates(isRunning: viscosityRunning),
        tailscaleStatus: tailscaleCLIStatus(serviceAttached: tailscaleAttached, routeLines: routes),
        hillstoneConnectionState: hillstoneConnectionState(),
        hillstoneServiceRunning: allProcesses.contains {
            $0.localizedCaseInsensitiveContains("HillstoneSecureConnectService")
        },
        byWaveHelperRunning: allProcesses.contains {
            $0.localizedCaseInsensitiveContains("/usr/local/bin/bywave-service")
        },
        byWaveTunEnabled: byWaveTunIsEnabled(),
        otherNetSwitchProcesses: allProcesses.filter {
            ($0.contains("/net-switch") || $0.contains(".build/release/net-switch"))
                && !$0.hasSuffix("net-switch guard")
                && !isShellCommandLine($0)
        }
    )
}

func statusFor(_ client: Client, snapshot: Snapshot) -> (String, String) {
    let running = snapshot.isRunning(client)
    switch client {
    case .v2rayn:
        if running {
            let routeHint = snapshot.utunRouteLines.isEmpty ? "未检测到 TUN 路由" : "检测到 TUN 路由"
            return ("运行中", routeHint)
        }
        return ("已停止", "可以检查代理残留")
    case .bywave:
        if running {
            if snapshot.proxyIsActive(client) {
                let tunHint = snapshot.byWaveTunEnabled ? "；TUN 同时启用" : ""
                return ("运行中", "系统代理正在使用 7893\(tunHint)")
            }
            let tunHint = snapshot.byWaveTunEnabled ? "ByWave TUN 正在接管网络" : "ByWave TUN 未启用"
            return ("运行中", "系统代理未开启；\(tunHint)")
        }
        let helper = snapshot.byWaveHelperRunning ? "；后台辅助服务待命（未接管网络）" : ""
        return ("已停止", "应用已退出\(helper)")
    case .clash:
        if running { return ("运行中", snapshot.proxyIsActive(client) ? "系统代理正在使用 7897" : "系统代理未开启") }
        return ("已停止", "可以检查代理残留")
    case .powervpn:
        let connected = snapshot.connectedVPNs.contains { $0.contains("小地球仪") }
        return (connected ? "已连接" : (running ? "运行中" : "已停止"), connected ? "请先在 PowerVPN 内断开，再退出" : "未检测到活动的 PowerVPN 服务")
    case .viscosity:
        let active = snapshot.hasActiveViscosityConnection
        return (active ? "已连接" : (running ? "运行中" : "已停止"), active ? snapshot.viscosityStates.joined(separator: "; ") : "未检测到活动的 Viscosity 连接")
    case .hillstone:
        switch snapshot.hillstoneConnectionState {
        case .connected:
            return ("已连接", "请先在 Hillstone 内手动断开，再安全退出")
        case .disconnected:
            if running { return ("运行中", "VPN 已断开，可以安全退出应用") }
            let helper = snapshot.hillstoneServiceRunning ? "；后台服务待命属于正常状态" : ""
            return ("已停止", "未检测到活动的 Hillstone 连接\(helper)")
        case .unknown:
            if running { return ("需检查", "无法确认 VPN 状态，请先在 Hillstone 内手动断开") }
            let helper = snapshot.hillstoneServiceRunning ? "后台服务待命，未发现界面程序" : "未检测到应用或连接"
            return ("已停止", helper)
        }
    case .tailscale:
        let status = snapshot.tailscaleStatus
        if status.isInertServiceAttached {
            return ("已停止", "后端已停止；macOS 网络扩展仍挂载，不影响后续切换")
        }
        if status.isEffectivelyActive {
            if status.usingExitNode {
                let online = status.exitNodeOnline == false ? "离线" : "在线"
                let path: String
                switch status.connectionPath {
                case .direct: path = "直连"
                case .relay: path = "DERP 中继 \(status.relayRegion ?? "未知")"
                case .unknown: path = "路径未知"
                }
                let lan = status.exitNodeAllowLANAccess ? "允许局域网" : "不允许局域网"
                return ("全局出口", "\(status.exitNodeName ?? "未知节点") \(online)，\(path)，\(lan)")
            }
            let peer = status.peerName ?? "目标节点"
            let online = status.peerOnline == false ? "离线" : "在线"
            let path: String
            switch status.connectionPath {
            case .direct: path = "直连"
            case .relay: path = "DERP 中继 \(status.relayRegion ?? "未知")"
            case .unknown: path = "路径未知"
            }
            return ("已连接", "仅 Tailnet 私网；\(peer) \(online)，\(path)")
        }
        if status.backendState == nil, status.serviceAttached {
            return ("需检查", "无法读取 Tailscale 后端状态，暂按活动连接保护")
        }
        return (running ? "运行中" : "已停止", running ? "应用已打开，但后端没有接管网络" : "未检测到活动的 Tailscale 服务")
    }
}

func printStatus(_ snapshot: Snapshot) {
    print(ANSI.paint("网络切换助手 - 当前状态", ANSI.bold + ANSI.cyan))
    print(String(format: "%-14@ %-12@ %@", "软件" as NSString, "状态" as NSString, "提示" as NSString))
    print(String(repeating: "-", count: 78))
    for client in Client.allCases {
        let (state, advice) = statusFor(client, snapshot: snapshot)
        let color = state == "已停止" ? ANSI.green : ANSI.yellow
        print(String(format: "%-14@ %-12@ %@", client.title as NSString, ANSI.paint(state, color) as NSString, advice as NSString))
    }
    let relevant = snapshot.proxyEntries.filter { managedLocalProxyPorts.contains($0.port) && isLocalHost($0.host) }
    print("\n系统代理设置：\(relevant.isEmpty ? ANSI.paint("无", ANSI.green) : ANSI.paint("\(relevant.count) 项", ANSI.yellow))")
    for entry in relevant {
        let state = proxyOwner(for: entry).map { snapshot.isRunning($0) ? "正在使用" : "残留" } ?? "状态未知"
        print("  \(entry.service): \(entry.type) \(entry.host):\(entry.port)（\(state)）")
    }
    print("虚拟网卡路由：\(snapshot.utunRouteLines.isEmpty ? ANSI.paint("无", ANSI.green) : ANSI.paint("正在接管网络", ANSI.yellow))")
    let modeColor = [.conflict, .degraded].contains(snapshot.networkMode) ? ANSI.red : ANSI.cyan
    print("当前网络模式：\(ANSI.paint(snapshot.networkMode.chineseLabel, modeColor))")
    if !snapshot.otherNetSwitchProcesses.isEmpty {
        print(ANSI.paint("提示：检测到 \(snapshot.otherNetSwitchProcesses.count) 个其他 net-switch 进程，可能是未退出的菜单或清理命令。工具不会自动结束它们。", ANSI.yellow))
    }
}

func snapshotSummary(_ snapshot: Snapshot) -> String {
    redactedStateSummary(
        runningClients: snapshot.runningClientNames,
        effectiveVPNs: snapshot.effectiveVPNNames,
        proxyCount: staleLocalProxyEntries(snapshot).count,
        hasUtunRoutes: !snapshot.utunRouteLines.isEmpty,
        v2Protected: false
    )
}

func openClient(_ client: Client) {
    let operationID = String(UUID().uuidString.prefix(8))
    log("操作开始 | 编号=\(operationID) | 打开 \(client.title)")
    let result = Shell.run("/usr/bin/open", ["-b", client.bundleID])
    guard result.status == 0 else {
        log("操作失败 | 编号=\(operationID) | \(client.title) 未能打开")
        print(ANSI.paint("处理失败：无法打开 \(client.title)，请确认应用仍已安装。", ANSI.red))
        return
    }
    log("操作成功 | 编号=\(operationID) | 已打开 \(client.title)")
    print(ANSI.paint("处理成功：已打开 \(client.title)，请在软件内手动连接。", ANSI.green))
}

func quitApplication(_ client: Client) -> Bool {
    let script = "tell application id \"\(client.bundleID)\" to quit"
    let result = Shell.run("/usr/bin/osascript", ["-e", script])
    if result.status != 0 { print("Could not request normal quit: \(result.output)") }
    return result.status == 0
}

func waitUntil(_ seconds: Int, _ predicate: () -> Bool) -> Bool {
    for _ in 0..<seconds {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 1)
    }
    return predicate()
}

func processIsRunning(_ client: Client) -> Bool {
    commandLines("/bin/ps", ["ax", "-o", "command="]).contains {
        matchesClientProcess($0, client: client)
    }
}

func clientProcessIDs(_ client: Client) -> [pid_t] {
    commandLines("/bin/ps", ["ax", "-o", "pid=,command="]).compactMap { row in
        let parts = row.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              let pid = pid_t(parts[0]),
              pid != ProcessInfo.processInfo.processIdentifier,
              matchesClientProcess(String(parts[1]), client: client) else { return nil }
        return pid
    }
}

func terminateClientProcesses(_ client: Client) -> Bool {
    var processIDs = clientProcessIDs(client)
    for pid in processIDs { _ = Darwin.kill(pid, SIGTERM) }
    if waitUntil(5, { clientProcessIDs(client).isEmpty }) { return true }
    processIDs = clientProcessIDs(client)
    for pid in processIDs { _ = Darwin.kill(pid, SIGKILL) }
    return waitUntil(2, { clientProcessIDs(client).isEmpty })
}

func effectiveSystemProxyUses(port: Int) -> Bool {
    let lines = commandLines("/usr/sbin/scutil", ["--proxy"])
    var values: [String: String] = [:]
    for line in lines {
        let parts = line.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2 { values[parts[0]] = parts[1] }
    }
    return [
        ("HTTPEnable", "HTTPPort"),
        ("HTTPSEnable", "HTTPSPort"),
        ("SOCKSEnable", "SOCKSPort")
    ].contains { enabledKey, portKey in
        values[enabledKey] == "1" && Int(values[portKey] ?? "") == port
    }
}

func powerVPNIsConnected() -> Bool {
    connectedVPNs().contains { $0.contains("小地球仪") }
}

func lightweightTailscaleStatus() -> TailscaleStatus {
    let routes = commandLines("/usr/sbin/netstat", ["-rn", "-f", "inet"]).filter { $0.contains("utun") }
    let attached = connectedVPNs().contains { $0.localizedCaseInsensitiveContains("Tailscale") }
    return tailscaleCLIStatus(serviceAttached: attached, routeLines: routes)
}

struct OperationContext {
    let id: String
    let title: String
    let startedAt: Date
    let before: String

    init(_ title: String, snapshot: Snapshot) {
        id = String(UUID().uuidString.prefix(8))
        self.title = title
        startedAt = Date()
        before = snapshotSummary(snapshot)
        log("操作开始 | 编号=\(id) | \(title) | 操作前=\(before)")
        print(ANSI.paint("正在处理：\(title)（编号 \(id)）", ANSI.cyan))
    }

    func finish(result: String, detail: String, after: Snapshot? = nil) {
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        let afterText = after.map(snapshotSummary) ?? "未重新扫描"
        log("操作\(result) | 编号=\(id) | \(title) | 耗时=\(elapsed)秒 | \(detail) | 操作后=\(afterText)")
    }
}

@discardableResult
func stopClient(_ client: Client, options: Set<String>) -> Bool {
    let snapshot = takeSnapshot()
    let operation = OperationContext("安全退出 \(client.title)", snapshot: snapshot)
    guard snapshot.isRunning(client) || client == .tailscale else {
        operation.finish(result: "取消", detail: "应用未运行", after: snapshot)
        print(ANSI.paint("无需处理：\(client.title) 当前没有运行。", ANSI.yellow))
        return false
    }
    switch client {
    case .v2rayn:
        let confirmed = options.contains("--yes")
            || (options.contains("--confirm-v2rayn") && options.contains("--confirm-risk"))
        guard confirmed else {
            operation.finish(result: "拒绝", detail: "缺少确认", after: snapshot)
            print(ANSI.paint("已拒绝：关闭 v2rayN 可能中断当前网络，请使用 --yes 明确确认。", ANSI.red))
            return false
        }
        _ = quitApplication(client)
        if !waitUntil(3, { !processIsRunning(.v2rayn) }) {
            guard terminateClientProcesses(.v2rayn) else {
                operation.finish(result: "失败", detail: "无法终止 v2rayN 残留进程")
                print(ANSI.paint("处理失败：v2rayN 仍有残留进程，请在活动监视器中检查。", ANSI.red))
                return false
            }
        }
    case .bywave:
        let confirmed = options.contains("--yes")
            || (options.contains("--confirm-bywave") && options.contains("--confirm-risk"))
        guard confirmed else {
            operation.finish(result: "拒绝", detail: "缺少确认", after: snapshot)
            print(ANSI.paint("已拒绝：关闭 ByWave 可能中断当前网络，请使用 --yes 明确确认。", ANSI.red))
            return false
        }
        if snapshot.byWaveTunEnabled {
            guard disableByWaveTun(), waitUntil(10, { !byWaveTunIsEnabled() }) else {
                operation.finish(result: "失败", detail: "ByWave TUN 未能通过本地控制接口释放")
                print(ANSI.paint("处理失败：ByWave TUN 仍在接管网络，已停止后续退出操作。", ANSI.red))
                return false
            }
        }
        guard quitApplication(client) else {
            operation.finish(result: "部分完成", detail: "TUN 已停用，但无法请求应用正常退出")
            print(ANSI.paint("部分完成：ByWave TUN 已停用，但应用未接受正常退出请求。", ANSI.yellow))
            return false
        }
        guard waitUntil(15, {
            !processIsRunning(.bywave) && !effectiveSystemProxyUses(port: 7893)
        }) else {
            let processActive = processIsRunning(.bywave)
            let proxyActive = effectiveSystemProxyUses(port: 7893)
            operation.finish(
                result: "部分完成",
                detail: "进程=\(processActive ? "仍运行" : "已退出"); 7893系统代理=\(proxyActive ? "仍启用" : "已释放")"
            )
            print(ANSI.paint("部分完成：已请求退出 ByWave，但仍需检查\(processActive ? "应用进程" : "")\(processActive && proxyActive ? "和" : "")\(proxyActive ? " 7893 系统代理" : "")。", ANSI.yellow))
            return false
        }
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: "TUN 已停用；应用进程已退出；7893 系统代理已释放；后台辅助服务未改动", after: after)
        print(ANSI.paint("处理成功：ByWave TUN 已停用，应用已退出，7893 系统代理已释放。", ANSI.green))
        return true
    case .clash:
        guard quitApplication(client) else {
            operation.finish(result: "失败", detail: "无法请求应用正常退出")
            print(ANSI.paint("处理失败：Clash Verge 未接受正常退出请求。", ANSI.red))
            return false
        }
        guard waitUntil(15, {
            !processIsRunning(.clash) && !effectiveSystemProxyUses(port: 7897)
        }) else {
            let processActive = processIsRunning(.clash)
            let proxyActive = effectiveSystemProxyUses(port: 7897)
            operation.finish(
                result: "部分完成",
                detail: "进程=\(processActive ? "仍运行" : "已退出"); 7897系统代理=\(proxyActive ? "仍启用" : "已释放")"
            )
            print(ANSI.paint("部分完成：已请求退出 Clash Verge，但仍需检查\(processActive ? "应用进程" : "")\(processActive && proxyActive ? "和" : "")\(proxyActive ? " 7897 系统代理" : "")。", ANSI.yellow))
            return false
        }
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: "应用进程已退出；7897 系统代理已释放", after: after)
        print(ANSI.paint("处理成功：Clash Verge 已退出，7897 系统代理已释放。", ANSI.green))
        return true
    case .viscosity:
        let script = "tell application id \"com.viscosityvpn.Viscosity\" to disconnectall"
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            operation.finish(result: "失败", detail: "自动化断开请求失败")
            print(ANSI.paint("处理失败：无法请求 Viscosity 断开连接，请检查 macOS 自动化权限。应用未被退出。", ANSI.red))
            return false
        }
        guard waitUntil(15, {
            !viscosityStates(isRunning: processIsRunning(.viscosity)).contains {
                !$0.localizedCaseInsensitiveContains("disconnected")
                    && !$0.localizedCaseInsensitiveContains("automation unavailable")
            }
        }) else {
            operation.finish(result: "部分完成", detail: "断开请求已发送，但仍检测到活动连接")
            print(ANSI.paint("部分完成：Viscosity 仍有活动连接，因此没有退出应用。请在应用内检查连接。", ANSI.yellow))
            return false
        }
        guard quitApplication(client), waitUntil(15, { !processIsRunning(.viscosity) }) else {
            operation.finish(result: "部分完成", detail: "连接已断开，但应用仍在运行")
            print(ANSI.paint("部分完成：Viscosity 连接已断开，但应用仍在运行。", ANSI.yellow))
            return false
        }
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: "连接已断开；应用已退出", after: after)
        print(ANSI.paint("处理成功：Viscosity 连接已断开，应用已退出。", ANSI.green))
        return true
    case .powervpn:
        guard !powerVPNIsConnected() else {
            operation.finish(result: "拒绝", detail: "小地球仪 VPN 服务仍连接", after: snapshot)
            print(ANSI.paint("已拒绝：小地球仪 VPN 服务仍连接。请先在 PowerVPN 内手动断开，再执行安全退出。", ANSI.red))
            return false
        }
        guard quitApplication(client), waitUntil(15, { !processIsRunning(.powervpn) }) else {
            operation.finish(result: "部分完成", detail: "VPN 已断开，但应用仍在运行")
            print(ANSI.paint("部分完成：小地球仪已断开，但 PowerVPN 应用仍在运行。", ANSI.yellow))
            return false
        }
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: "小地球仪已断开；应用已退出", after: after)
        print(ANSI.paint("处理成功：PowerVPN 已安全退出，小地球仪保持断开。", ANSI.green))
        return true
    case .hillstone:
        guard snapshot.hillstoneConnectionState == .disconnected else {
            let detail = snapshot.hillstoneConnectionState == .connected
                ? "检测到 Hillstone VPN 仍连接"
                : "无法确认 Hillstone VPN 已断开"
            operation.finish(result: "拒绝", detail: detail, after: snapshot)
            print(ANSI.paint("已拒绝：\(detail)。请先在 Hillstone 内手动断开，再执行安全退出。", ANSI.red))
            return false
        }
        guard quitApplication(client), waitUntil(15, { !processIsRunning(.hillstone) }) else {
            operation.finish(result: "部分完成", detail: "VPN 已断开，但应用仍在运行")
            print(ANSI.paint("部分完成：Hillstone VPN 已断开，但应用仍在运行。后台服务不会被工具停止。", ANSI.yellow))
            return false
        }
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: "连接已断开；应用已退出；后台服务保持待命", after: after)
        print(ANSI.paint("处理成功：Hillstone 已断开并退出，系统后台服务保持待命。", ANSI.green))
        return true
    case .tailscale:
        guard options.contains("--yes") else {
            let exitHint = snapshot.tailscaleStatus.usingExitNode
                ? "当前正在使用 Exit Node，关闭后海外网络可能立即中断。"
                : "关闭后 FinalShell 的 Tailscale 私网连接将不可用。"
            operation.finish(result: "拒绝", detail: "缺少确认", after: snapshot)
            print(ANSI.paint("已拒绝：\(exitHint) 请使用 --yes 明确确认。", ANSI.red))
            return false
        }
        let result = Shell.run("/usr/local/bin/tailscale", ["down"])
        guard result.status == 0 else {
            operation.finish(result: "失败", detail: "官方断开命令执行失败")
            print(ANSI.paint("处理失败：Tailscale 未能完成断开，请在 Tailscale 应用内检查状态。", ANSI.red))
            return false
        }
        guard waitUntil(15, { lightweightTailscaleStatus().isSafelyStopped }) else {
            let status = lightweightTailscaleStatus()
            let reason = status.hasOwnedRoutes ? "仍有 Tailscale 专属路由" : "后端状态为 \(status.backendState ?? "未知")"
            operation.finish(result: "部分完成", detail: reason)
            print(ANSI.paint("部分完成：已发送断开请求，但\(reason)。请在 Tailscale 应用内检查。", ANSI.yellow))
            return false
        }
        let finalStatus = lightweightTailscaleStatus()
        let detail = finalStatus.serviceAttached
            ? "后端已停止；无专属路由；macOS 网络扩展仍挂载（不影响切换）"
            : "后端已停止；无专属路由；网络服务已释放"
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: detail, after: after)
        print(ANSI.paint("处理成功：Tailscale 后端已停止且没有专属路由。", ANSI.green))
        if finalStatus.serviceAttached {
            print(ANSI.paint("提示：macOS 网络扩展仍显示挂载，这是非活动状态，不会阻止后续代理切换。", ANSI.yellow))
        }
        return true
    }
    let stopped = waitUntil(15, { !processIsRunning(client) })
    if stopped {
        let after = takeSnapshot()
        operation.finish(result: "成功", detail: "应用已正常退出", after: after)
        print(ANSI.paint("处理成功：\(client.title) 已正常退出。", ANSI.green))
        return true
    }
    operation.finish(result: "部分完成", detail: "已请求退出，但应用进程仍运行")
    print(ANSI.paint("部分完成：已请求退出 \(client.title)，但应用仍在运行，请手动检查。", ANSI.yellow))
    return false
}

func staleLocalProxyEntries(_ snapshot: Snapshot) -> [ProxyEntry] {
    snapshot.proxyEntries.filter { managedLocalProxyPorts.contains($0.port) && isLocalHost($0.host) }
}

func activityBlockers(_ snapshot: Snapshot) -> [String] {
    var blockers: [String] = []
    let activeClients = Client.allCases.filter {
        $0 != .tailscale && snapshot.isRunning($0)
    }.map(\.title)
    if !activeClients.isEmpty {
        blockers.append("运行中的客户端：\(activeClients.joined(separator: "、"))")
    }
    let nonMeshVPNs = snapshot.effectiveVPNNames.filter {
        $0 != "Tailscale" || snapshot.tailscaleStatus.usingExitNode
    }
    if !nonMeshVPNs.isEmpty {
        blockers.append("活动 VPN：\(nonMeshVPNs.joined(separator: "、"))")
    }
    if !snapshot.utunRouteLines.isEmpty && (snapshot.hasOtherNetworkOwner || snapshot.tailscaleStatus.usingExitNode) {
        blockers.append("仍有 utun 虚拟网卡路由")
    }
    return blockers
}

@discardableResult
func repair(_ confirmed: Bool, automatic: Bool = false) -> Bool {
    let snapshot = takeSnapshot()
    let stale = staleLocalProxyEntries(snapshot)
    if automatic && snapshot.hasActivity {
        let blockers = activityBlockers(snapshot)
        log("修复拒绝 | \(blockers.joined(separator: "；")) | 状态=\(snapshotSummary(snapshot))")
        return false
    }
    guard !stale.isEmpty else {
        log("修复检查 | 未发现受管本地代理残留")
        if !automatic { print(ANSI.paint("检查完成：未发现 10808/7893/7897 本地系统代理残留。", ANSI.green)) }
        return true
    }
    guard confirmed else {
        log("修复预检 | 发现 \(stale.count) 项受管本地代理残留，等待确认")
        print(ANSI.paint("检查完成：发现以下受管本地系统代理：", ANSI.yellow))
        for entry in stale { print("  \(entry.service): \(entry.type) \(entry.host):\(entry.port)") }
        if snapshot.hasActivity {
            print(ANSI.paint("提示：代理客户端仍在运行；强制清理后，客户端可能再次写入这些设置。", ANSI.yellow))
        }
        print("请从主菜单选择“强制清理系统代理”，并按提示确认。")
        return true
    }
    if snapshot.hasActivity {
        log("强制修复 | 用户确认在客户端运行期间清理系统代理 | 状态=\(snapshotSummary(snapshot))")
        if !automatic {
            print(ANSI.paint("警告：正在强制清理系统代理，运行中的客户端可能再次写入设置。", ANSI.yellow))
        }
    }
    log("修复开始 | 清理 \(stale.count) 项受管本地代理残留")
    let commands: [(String, String)] = [
        ("HTTP", "-setwebproxystate"),
        ("HTTPS", "-setsecurewebproxystate"),
        ("SOCKS", "-setsocksfirewallproxystate")
    ]
    var failures: [String] = []
    for entry in stale {
        guard let command = commands.first(where: { $0.0 == entry.type })?.1 else { continue }
        let result = Shell.run("/usr/sbin/networksetup", [command, entry.service, "off"])
        if result.status != 0 { failures.append("\(entry.service) \(entry.type): \(result.output)") }
    }
    if failures.isEmpty {
        log("修复完成 | 已清理 \(stale.count) 项受管本地代理残留")
        print(ANSI.paint("处理成功：已关闭 \(stale.count) 项受管本地系统代理。", ANSI.green))
        return true
    } else {
        log("修复失败 | 部分受管本地代理残留未能清理")
        print(ANSI.paint("处理失败：部分本地代理未能关闭，请运行“net 诊断”收集信息。", ANSI.red))
        return false
    }
}

struct ModeSnapshot {
    let exitNodeName: String?
    let exitNodeAllowLANAccess: Bool
    let clashRunning: Bool
    let proxyEntries: [ProxyEntry]
}

func transitionLockURL() -> URL {
    logsDirectory().appendingPathComponent("mode-transition.lock")
}

func setTransitionLock(_ enabled: Bool) {
    let file = transitionLockURL()
    if enabled {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: file, options: .atomic)
    } else {
        try? FileManager.default.removeItem(at: file)
    }
}

func transitionIsActive() -> Bool {
    let file = transitionLockURL()
    guard FileManager.default.fileExists(atPath: file.path) else { return false }
    guard let text = try? String(contentsOf: file, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          Darwin.kill(pid, 0) == 0 else {
        try? FileManager.default.removeItem(at: file)
        return false
    }
    return true
}

func proxyStateCommand(for type: String) -> String? {
    ["HTTP": "-setwebproxystate", "HTTPS": "-setsecurewebproxystate", "SOCKS": "-setsocksfirewallproxystate"][type]
}

func proxySetCommand(for type: String) -> String? {
    ["HTTP": "-setwebproxy", "HTTPS": "-setsecurewebproxy", "SOCKS": "-setsocksfirewallproxy"][type]
}

@discardableResult
func disableManagedProxy(port: Int) -> Bool {
    let entries = currentProxyEntries().filter { $0.port == port && isLocalHost($0.host) }
    return entries.allSatisfy { entry in
        guard let command = proxyStateCommand(for: entry.type) else { return false }
        return Shell.run("/usr/sbin/networksetup", [command, entry.service, "off"]).status == 0
    }
}

@discardableResult
func enableSystemProxy(port: Int) -> Bool {
    var success = true
    for service in networkServices() {
        for type in ["HTTP", "HTTPS", "SOCKS"] {
            guard let set = proxySetCommand(for: type), let state = proxyStateCommand(for: type) else { continue }
            let configured = Shell.run("/usr/sbin/networksetup", [set, service, "127.0.0.1", "\(port)"]).status == 0
            let enabled = configured && Shell.run("/usr/sbin/networksetup", [state, service, "on"]).status == 0
            success = success && enabled
        }
    }
    return success
}

func restoreProxyEntries(_ entries: [ProxyEntry]) {
    for port in managedLocalProxyPorts { _ = disableManagedProxy(port: port) }
    for entry in entries {
        guard let set = proxySetCommand(for: entry.type), let state = proxyStateCommand(for: entry.type) else { continue }
        _ = Shell.run("/usr/sbin/networksetup", [set, entry.service, entry.host, "\(entry.port)"])
        _ = Shell.run("/usr/sbin/networksetup", [state, entry.service, "on"])
    }
}

func tailscaleSetExitNode(_ name: String?, allowLAN: Bool = true) -> Bool {
    let value = name.map { "--exit-node=\($0)" } ?? "--exit-node="
    let result = Shell.run("/usr/local/bin/tailscale", ["set", value, "--exit-node-allow-lan-access=\(allowLAN ? "true" : "false")"], timeout: 10)
    if result.status != 0 { log("模式切换步骤失败 | Tailscale Exit Node 更新失败") }
    return result.status == 0
}

func tcpReachable(host: String, port: Int) -> Bool {
    Shell.run("/usr/bin/nc", ["-G", "4", "-z", host, "\(port)"], timeout: 5).status == 0
}

func curlProbe(_ url: String, proxyPort: Int? = nil) -> (ok: Bool, summary: String) {
    var arguments = ["-sS", "-L", "--max-time", "10", "-o", "/dev/null", "-w", "%{http_code} %{time_total}"]
    if let proxyPort {
        arguments += ["--proxy", "http://127.0.0.1:\(proxyPort)"]
    } else {
        arguments += ["--noproxy", "*"]
    }
    arguments.append(url)
    let result = Shell.run("/usr/bin/curl", arguments, timeout: 12)
    let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let code = Int(value.split(separator: " ").first ?? "0") ?? 0
    return (result.status == 0 && code >= 200 && code < 500, value.isEmpty ? "失败" : value)
}

func curlProbeSucceeds(_ url: String, proxyPort: Int? = nil, attempts: Int = 3) -> Bool {
    for attempt in 1...attempts {
        if curlProbe(url, proxyPort: proxyPort).ok { return true }
        if attempt < attempts { Thread.sleep(forTimeInterval: 1) }
    }
    return false
}

func captureModeSnapshot() -> ModeSnapshot {
    let snapshot = takeSnapshot()
    return ModeSnapshot(
        exitNodeName: snapshot.tailscaleStatus.exitNodeName,
        exitNodeAllowLANAccess: snapshot.tailscaleStatus.exitNodeAllowLANAccess,
        clashRunning: snapshot.isRunning(.clash),
        proxyEntries: snapshot.proxyEntries.filter { managedLocalProxyPorts.contains($0.port) && isLocalHost($0.host) }
    )
}

func restoreModeSnapshot(_ saved: ModeSnapshot) {
    _ = tailscaleSetExitNode(saved.exitNodeName, allowLAN: saved.exitNodeAllowLANAccess)
    if saved.clashRunning && !processIsRunning(.clash) {
        _ = Shell.run("/usr/bin/open", ["-b", Client.clash.bundleID])
        _ = waitUntil(10) { portIsListening(clashProxyPort) }
    } else if !saved.clashRunning && processIsRunning(.clash) {
        _ = quitApplication(.clash)
        _ = waitUntil(10) { !processIsRunning(.clash) }
    }
    restoreProxyEntries(saved.proxyEntries)
}

func printModeStatus(_ snapshot: Snapshot = takeSnapshot()) {
    let mode = snapshot.networkMode
    print(ANSI.paint("当前网络模式：\(mode.chineseLabel)", [.conflict, .degraded].contains(mode) ? ANSI.red : ANSI.cyan))
    if snapshot.tailscaleStatus.usingExitNode {
        print("Tailscale Exit Node：\(snapshot.tailscaleStatus.exitNodeName ?? "未知")")
    } else {
        print("Tailscale Exit Node：未启用（仅 Tailnet 私网）")
    }
    print("Clash 系统代理：\(effectiveSystemProxyUses(port: clashProxyPort) ? "127.0.0.1:\(clashProxyPort)" : "未启用")")
}

@discardableResult
func changeNetworkMode(_ target: NetworkMode, confirmed: Bool) -> Bool {
    guard [.split, .fallback, .direct].contains(target) else { return false }
    guard confirmed else {
        print(ANSI.paint("此操作会改变当前网络路径。请交互输入 y/yes，或在命令末尾添加 --yes。", ANSI.yellow))
        guard confirmYesNo("切换到\(target.chineseLabel)模式吗？") else { print("已取消。"); return false }
        return changeNetworkMode(target, confirmed: true)
    }
    let before = takeSnapshot()
    let operation = OperationContext("切换到\(target.chineseLabel)模式", snapshot: before)
    let saved = captureModeSnapshot()
    setTransitionLock(true)
    defer { setTransitionLock(false) }

    func rollback(_ reason: String) -> Bool {
        log("模式切换失败 | 编号=\(operation.id) | 原因=\(reason) | 开始回滚")
        restoreModeSnapshot(saved)
        let after = takeSnapshot()
        operation.finish(result: "失败", detail: "\(reason)；已执行回滚", after: after)
        print(ANSI.paint("切换失败：\(reason)。已恢复操作前的网络状态。", ANSI.red))
        return false
    }

    switch target {
    case .split:
        guard before.tailscaleStatus.isEffectivelyActive else { return rollback("Tailscale 尚未连接") }
        guard !before.hasOtherNetworkOwner else { return rollback("检测到 Clash 之外的其他网络客户端") }
        let reachablePorts = [443, 9443, 22].filter { tcpReachable(host: splitVPSAddress, port: $0) }
        guard !reachablePorts.isEmpty else { return rollback("Tailscale 私网 AnyTLS、VLESS 和 SSH 端口均不可达") }
        if !processIsRunning(.clash) {
            guard Shell.run("/usr/bin/open", ["-b", Client.clash.bundleID]).status == 0 else { return rollback("无法启动 Clash Verge") }
        }
        guard waitUntil(15, { portIsListening(clashProxyPort) }) else { return rollback("Clash 本地 7897 端口没有监听") }
        guard curlProbeSucceeds("https://www.google.com/generate_204", proxyPort: clashProxyPort) else {
            return rollback("取消 Exit Node 前的 Clash 海外预检失败")
        }
        guard tailscaleSetExitNode(nil), waitUntil(12, { !lightweightTailscaleStatus().usingExitNode }) else {
            return rollback("无法取消 Tailscale Exit Node")
        }
        guard enableSystemProxy(port: clashProxyPort), effectiveSystemProxyUses(port: clashProxyPort) else {
            return rollback("无法启用 Clash 系统代理")
        }
        guard curlProbeSucceeds("https://www.baidu.com", attempts: 2) else { return rollback("国内直连检查失败") }
        guard curlProbeSucceeds("https://www.google.com/generate_204", proxyPort: clashProxyPort) else {
            return rollback("海外代理检查失败")
        }
    case .fallback:
        if processIsRunning(.clash) {
            guard quitApplication(.clash), waitUntil(15, { !processIsRunning(.clash) }) else {
                return rollback("Clash Verge 未能安全退出")
            }
        }
        guard disableManagedProxy(port: clashProxyPort) else { return rollback("无法释放 Clash 系统代理") }
        guard tailscaleSetExitNode(splitVPSName), waitUntil(12, { lightweightTailscaleStatus().usingExitNode }) else {
            return rollback("无法启用 vps-2026 Exit Node")
        }
        guard curlProbeSucceeds("https://www.google.com/generate_204") else { return rollback("Exit Node 海外连通检查失败") }
    case .direct:
        if processIsRunning(.clash) {
            guard quitApplication(.clash), waitUntil(15, { !processIsRunning(.clash) }) else {
                return rollback("Clash Verge 未能安全退出")
            }
        }
        guard disableManagedProxy(port: clashProxyPort) else { return rollback("无法释放 Clash 系统代理") }
        guard tailscaleSetExitNode(nil), waitUntil(12, { !lightweightTailscaleStatus().usingExitNode }) else {
            return rollback("无法取消 Tailscale Exit Node")
        }
        guard curlProbe("https://www.baidu.com").ok else { return rollback("本地直连检查失败") }
    default: return false
    }
    let after = takeSnapshot()
    guard after.networkMode == target else { return rollback("状态复核得到\(after.networkMode.chineseLabel)而非\(target.chineseLabel)") }
    operation.finish(result: "成功", detail: "模式=\(target.chineseLabel)", after: after)
    print(ANSI.paint("处理成功：已切换到\(target.chineseLabel)模式。", ANSI.green))
    printModeStatus(after)
    return true
}

func networkDiagnostic() {
    let snapshot = takeSnapshot()
    print(ANSI.paint("网络路径诊断（只读）", ANSI.bold + ANSI.cyan))
    printModeStatus(snapshot)
    print("Tailscale 私网 443：\(tcpReachable(host: splitVPSAddress, port: 443) ? "可达" : "不可达")")
    print("Tailscale 私网 SSH：\(tcpReachable(host: splitVPSAddress, port: 22) ? "可达" : "不可达")")
    let directCN = curlProbe("https://www.baidu.com")
    let directGlobal = curlProbe("https://www.google.com/generate_204")
    print("默认路径 / 百度：\(directCN.ok ? "成功" : "失败")（\(directCN.summary)）")
    print("默认路径 / Google：\(directGlobal.ok ? "成功" : "失败")（\(directGlobal.summary)）")
    if portIsListening(clashProxyPort) {
        let proxyGlobal = curlProbe("https://www.google.com/generate_204", proxyPort: clashProxyPort)
        let proxyChatGPT = curlProbe("https://chatgpt.com", proxyPort: clashProxyPort)
        print("Clash 7897 / Google：\(proxyGlobal.ok ? "成功" : "失败")（\(proxyGlobal.summary)）")
        print("Clash 7897 / ChatGPT：\(proxyChatGPT.ok ? "成功" : "失败")（\(proxyChatGPT.summary)）")
    } else {
        print("Clash 7897：未监听，跳过代理路径测试")
    }
    let dns = Shell.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "chatgpt.com"], timeout: 5)
    print("DNS / chatgpt.com：\(dns.status == 0 && !dns.output.isEmpty ? "成功" : "失败")")
    log("操作 | 网络路径诊断 | 模式=\(snapshot.networkMode.chineseLabel) | 国内=\(directCN.ok ? "成功" : "失败") | 默认海外=\(directGlobal.ok ? "成功" : "失败") | Clash监听=\(portIsListening(clashProxyPort) ? "是" : "否")")
}

func logsDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/net-switch", isDirectory: true)
}

func pruneOldLogs() {
    let directory = logsDirectory()
    let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }
    for file in files where
        (file.lastPathComponent.hasPrefix("events-") || file.lastPathComponent.hasPrefix("diagnostic-"))
        && ["log", "txt"].contains(file.pathExtension) {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
    }
}

func log(_ text: String) {
    let directory = logsDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    pruneOldLogs()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let file = directory.appendingPathComponent("events-\(formatter.string(from: Date())).log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) | \(text)\n"
    if FileManager.default.fileExists(atPath: file.path), let handle = try? FileHandle(forWritingTo: file) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: file)
    }
}

func showRecentLogs() {
    let directory = logsDirectory()
    pruneOldLogs()
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ).filter({ $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "log" })
    .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), let latest = files.first else {
        print("暂时没有操作日志。使用菜单操作、查看状态或启动后台守护后会自动创建。")
        return
    }
    let lines = (try? String(contentsOf: latest, encoding: .utf8))?.split(separator: "\n").suffix(80) ?? []
    print(ANSI.paint("最近日志：\(latest.path)", ANSI.bold + ANSI.cyan))
    if lines.isEmpty { print("日志文件为空。") } else { lines.forEach { print($0) } }
    print("\n说明：launchd.log 只接收后台标准输出，通常为空；实际操作和状态事件记录在上面的 events 日志中。")
    log("操作 | 查看最近日志")
}

func openLogsDirectory() {
    let directory = logsDirectory()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneOldLogs()
        let result = Shell.run("/usr/bin/open", [directory.path])
        guard result.status == 0 else {
            log("操作失败 | 无法在 Finder 打开日志目录")
            print(ANSI.paint("无法自动打开日志目录，请在 Finder 中按 Command-Shift-G 并输入下面路径：", ANSI.red))
            print(directory.path)
            return
        }
        log("操作成功 | 已在 Finder 打开日志目录")
        print(ANSI.paint("已在 Finder 打开日志目录：", ANSI.green))
        print(directory.path)
    } catch {
        log("操作失败 | 无法创建日志目录")
        print(ANSI.paint("无法准备日志目录：\(directory.path)", ANSI.red))
    }
}

func sanitizedLogLine(_ line: String) -> String {
    redactSensitiveText(
        line,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )
}

func recentExceptionalLogLines(limit: Int) -> [String] {
    let directory = logsDirectory()
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).filter({ $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "log" })
        .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return [] }
    let markers = ["失败", "拒绝", "异常", "部分完成"]
    return files.prefix(3).flatMap { file in
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { line in markers.contains { line.contains($0) } }
    }.suffix(limit).map(sanitizedLogLine)
}

func clashLogsDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/logs", isDirectory: true)
}

func recentClashExceptionalLogLines(limit: Int) -> [String] {
    let directory = clashLogsDirectory()
    let candidates = [
        directory.appendingPathComponent("sidecar/sidecar_latest.log"),
        directory.appendingPathComponent("latest.log")
    ]
    let markers = ["level=error", "level=warning", " error ", " warn ", "timeout", "deadline", "reset", "failed"]
    return candidates.flatMap { file -> [String] in
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { line in
            let lowered = line.lowercased()
            return logLineIsWithin(line, hours: 24)
                && markers.contains { lowered.contains($0) }
        }
    }.suffix(limit).map(sanitizedLogLine)
}

func showRecentClashLogs() {
    let lines = recentClashExceptionalLogLines(limit: 80)
    print(ANSI.paint("Clash Verge 最近 24 小时警告与错误（已脱敏）", ANSI.bold + ANSI.cyan))
    if lines.isEmpty {
        print("当前持久化日志中没有发现警告、超时或错误。")
    } else {
        lines.forEach { print($0) }
    }
    print("\n更早的历史记录已省略。原始日志目录：\(clashLogsDirectory().path)")
    log("操作 | 查看 Clash Verge 最近 24 小时警告与错误 | 条数=\(lines.count)")
}

func guardProcessStatus() -> String {
    let result = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/local.net-switch.guard"])
    guard result.status == 0 else { return "未加载" }
    return result.output.contains("state = running") ? "运行中" : "已加载但未运行"
}

func portIsListening(_ port: Int) -> Bool {
    Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).status == 0
}

@discardableResult
func generateDiagnosticReport() -> URL? {
    let snapshot = takeSnapshot()
    let directory = logsDirectory()
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneOldLogs()
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appendingPathComponent("diagnostic-\(timestamp.string(from: Date())).txt")
        let tailscale = snapshot.tailscaleStatus
        let recent = recentExceptionalLogLines(limit: 20)
        let clashRecent = recentClashExceptionalLogLines(limit: 20)
        let report = """
        net-switch 脱敏诊断报告
        生成时间：\(ISO8601DateFormatter().string(from: Date()))

        当前状态
        \(snapshotSummary(snapshot))
        Tailscale 后端：\(tailscale.backendState ?? "无法读取")
        Tailscale 有效活动：\(tailscale.isEffectivelyActive ? "是" : "否")
        Tailscale 网络扩展挂载：\(tailscale.serviceAttached ? "是" : "否")
        Tailscale 专属路由：\(tailscale.hasOwnedRoutes ? "有" : "无")
        Tailscale Exit Node：\(tailscale.usingExitNode ? "已启用（\(tailscale.exitNodeName ?? "未知")）" : "未启用")
        Tailscale Exit Node 在线：\(tailscale.exitNodeOnline.map { $0 ? "是" : "否" } ?? "不适用")
        Tailscale 目标节点：\(tailscale.peerName ?? "未知")（\(tailscale.peerOnline.map { $0 ? "在线" : "离线" } ?? "未知")）
        Tailscale 连接路径：\(tailscale.connectionPath.rawValue)\(tailscale.relayRegion.map { "（\($0)）" } ?? "")
        Tailscale 允许局域网：\(tailscale.exitNodeAllowLANAccess ? "是" : "否")
        当前网络模式：\(snapshot.networkMode.chineseLabel)
        Hillstone 连接状态：\(hillstoneStateLabel(snapshot.hillstoneConnectionState))
        Hillstone 后台服务：\(snapshot.hillstoneServiceRunning ? "待命" : "未运行")
        ByWave 后台辅助服务：\(snapshot.byWaveHelperRunning ? "待命（未代表应用运行）" : "未运行")
        10808 监听：\(portIsListening(10808) ? "是" : "否")
        7893 监听：\(portIsListening(7893) ? "是" : "否")
        7897 监听：\(portIsListening(7897) ? "是" : "否")
        utun 路由：\(snapshot.utunRouteLines.isEmpty ? "无" : "有（\(snapshot.utunRouteLines.count) 条，不记录内容）")
        其他 net-switch 进程：\(snapshot.otherNetSwitchProcesses.count)
        后台守护：\(guardProcessStatus())

        最近异常（已脱敏）
        \(recent.isEmpty ? "无" : recent.joined(separator: "\n"))

        Clash Verge 最近 24 小时警告与错误（已脱敏；更早历史已省略）
        \(clashRecent.isEmpty ? "无" : clashRecent.joined(separator: "\n"))

        隐私说明
        本报告不记录节点、订阅、账号、密码、服务器地址、完整路由表或完整命令输出。
        """
        try Data(report.utf8).write(to: file, options: .atomic)
        log("操作成功 | 已生成脱敏诊断报告 \(file.lastPathComponent)")
        print(ANSI.paint("诊断报告已生成：", ANSI.green))
        print(file.path)
        return file
    } catch {
        log("操作失败 | 无法生成脱敏诊断报告")
        print(ANSI.paint("处理失败：无法生成诊断报告。", ANSI.red))
        return nil
    }
}

func logsAndDiagnosticsMenu() {
    print("""

日志与诊断：
  1. 查看最近日志    显示最近 80 条记录
  2. 打开日志目录    在 Finder 中打开隐藏目录
  3. 生成诊断报告    保存脱敏后的状态与最近异常
  4. Clash 日志     显示 Clash Verge 最近警告与错误
  0. 返回
""")
    print("请输入数字：", terminator: "")
    switch readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "1": showRecentLogs()
    case "2": openLogsDirectory()
    case "3": _ = generateDiagnosticReport()
    case "4": showRecentClashLogs()
    default: return
    }
}

func guardLoop() -> Never {
    log("守护启动 | 每 5 秒检查，空闲 10 秒后仅清理受管本地代理残留")
    var quietSince: Date?
    var lastSummary = ""
    while true {
        if transitionIsActive() {
            quietSince = nil
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        let snapshot = takeSnapshot()
        let summary = snapshotSummary(snapshot)
        if summary != lastSummary { log("守护状态 | \(summary)"); lastSummary = summary }
        if snapshot.hasActivity {
            quietSince = nil
        } else if let since = quietSince, Date().timeIntervalSince(since) >= 10 {
            if !staleLocalProxyEntries(snapshot).isEmpty {
                log("自动修复开始 | 已空闲 10 秒")
                repair(true, automatic: true)
                log("自动修复结束")
            }
            quietSince = Date()
        } else {
            quietSince = Date()
        }
        Thread.sleep(forTimeInterval: 5)
    }
}

func plistPath() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.net-switch.guard.plist")
}

func legacyPlistPath() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.chenlang.net-switch.plist")
}

func removeLegacyAgentIfPresent() {
    let legacyPath = legacyPlistPath()
    guard FileManager.default.fileExists(atPath: legacyPath.path) else { return }
    _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", legacyPath.path])
    try? FileManager.default.removeItem(at: legacyPath)
    log("守护迁移 | 已移除旧版 com.chenlang.net-switch，避免重复运行")
}

func installAgent() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    guard executable.hasPrefix("/") else { fail("Install requires an absolute path to the built net-switch executable.") }
    let path = plistPath()
    let plist: [String: Any] = [
        "Label": "local.net-switch.guard",
        "ProgramArguments": [executable, "guard"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": logsDirectory().appendingPathComponent("launchd.log").path,
        "StandardErrorPath": logsDirectory().appendingPathComponent("launchd.log").path
    ]
    do {
        removeLegacyAgentIfPresent()
        try FileManager.default.createDirectory(at: logsDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: path, options: .atomic)
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", path.path])
        let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", path.path])
        guard result.status == 0 else { fail("LaunchAgent file was written but could not start: \(result.output)") }
        log("守护安装 | 已注册登录后自动启动")
        print("Installed net-switch guard. Log: \(logsDirectory().path)")
    } catch { fail("Could not install LaunchAgent: \(error.localizedDescription)") }
}

func uninstallAgent() {
    let path = plistPath()
    _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", path.path])
    removeLegacyAgentIfPresent()
    do {
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        log("守护卸载 | 已移除登录后自动启动")
        print("Removed net-switch LaunchAgent.")
    } catch { fail("Could not remove LaunchAgent: \(error.localizedDescription)") }
}

final class WatchInterruptState {
    private let lock = NSLock()
    private var value = false

    var interrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markInterrupted() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

func sleepUnlessInterrupted(seconds: TimeInterval, state: WatchInterruptState) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline && !state.interrupted {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func watch(returningToMenu: Bool = false) {
    log("操作 | 开始持续监看")
    let interruptState = WatchInterruptState()
    let interruptQueue = DispatchQueue(label: "net-switch.watch.interrupt")
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: interruptQueue)
    let previousInterruptHandler = signal(SIGINT, SIG_IGN)
    interruptSource.setEventHandler {
        interruptState.markInterrupted()
    }
    interruptSource.resume()
    defer {
        interruptSource.cancel()
        signal(SIGINT, previousInterruptHandler)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"

    while !interruptState.interrupted {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        printStatus(takeSnapshot())
        print("\n最后刷新：\(formatter.string(from: Date()))")
        print(returningToMenu ? "每 5 秒刷新一次，按 Ctrl-C 返回菜单。" : "每 5 秒刷新一次，按 Ctrl-C 返回终端。")
        fflush(stdout)
        sleepUnlessInterrupted(seconds: 5, state: interruptState)
    }

    print("\n已退出持续监看。")
    if returningToMenu {
        Thread.sleep(forTimeInterval: 0.5)
    }
}

func waitForMenu() {
    print("\n按回车键返回菜单...", terminator: "")
    _ = readLine()
}

func chooseClient() -> Client? {
    print("\n请选择软件：")
    for (index, client) in Client.allCases.enumerated() {
        print("  \(index + 1). \(client.title)")
    }
    print("  0. 返回")
    print("请输入数字：", terminator: "")
    guard let text = readLine(), let index = Int(text), index > 0, index <= Client.allCases.count else { return nil }
    return Client.allCases[index - 1]
}

func networkModeMenu() {
    print("""

网络模式：
  1. 分流    国内直连，海外经 Clash + Tailscale 私网 VPS
  2. 兜底    所有公网流量经 Tailscale Exit Node
  3. 直连    本地公网直连，Tailscale 仅保留私网连接
  4. 查看    只显示当前模式
  0. 返回
""")
    print("请输入数字：", terminator: "")
    switch readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "1": _ = changeNetworkMode(.split, confirmed: false)
    case "2": _ = changeNetworkMode(.fallback, confirmed: false)
    case "3": _ = changeNetworkMode(.direct, confirmed: false)
    case "4": printModeStatus()
    default: return
    }
}

func interactiveMenu() -> Never {
    while true {
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        let snapshot = takeSnapshot()
        printStatus(snapshot)
        print("""

请选择操作：
  1. 刷新状态        查看当前谁正在接管网络
  2. 持续监看        每 5 秒自动刷新，按 Ctrl-C 返回菜单
  3. 打开软件        只打开，不自动连接
  4. 安全退出软件    按软件规则断开并退出
  5. 检查代理残留    只查看，不改动网络
  6. 强制清理系统代理 运行中也可执行，需 y/yes 确认
  7. 开机自动守护    安装后台检查与自动清理
  8. 日志与诊断      查看日志、打开目录或生成脱敏报告
  9. 网络模式        分流、兜底、直连与当前状态
  0. 退出助手
""")
        print("请输入数字：", terminator: "")
        guard let choice = readLine() else { exit(0) }
        log("菜单操作 | 选择 \(choice.trimmingCharacters(in: .whitespacesAndNewlines))")

        switch choice.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1", "": continue
        case "2": watch(returningToMenu: true)
        case "3":
            if let client = chooseClient() { openClient(client); waitForMenu() }
        case "4":
            guard let client = chooseClient() else { continue }
            if client == .v2rayn || client == .bywave || client == .tailscale {
                print(ANSI.paint("警告：关闭 \(client.title) 可能中断当前海外网络与 Codex 会话。", ANSI.red))
                guard confirmYesNo("确定继续吗？") else { print("已取消。"); waitForMenu(); continue }
                stopClient(client, options: ["--yes"])
            } else {
                stopClient(client, options: [])
            }
            waitForMenu()
        case "5":
            repair(false)
            waitForMenu()
        case "6":
            if confirmYesNo("将关闭 10808/7893/7897 的系统代理设置，即使客户端仍在运行也继续吗？") {
                repair(true)
            } else { print("已取消。") }
            waitForMenu()
        case "7":
            if confirmYesNo("安装登录后常驻的后台守护吗？") { installAgent() } else { print("已取消。") }
            waitForMenu()
        case "8":
            logsAndDiagnosticsMenu()
            waitForMenu()
        case "9":
            networkModeMenu()
            waitForMenu()
        case "0", "q", "Q": exit(0)
        default:
            print("无效选项，请输入 0 到 9。")
            waitForMenu()
        }
    }
}

func fail(_ message: String) -> Never {
    log("异常 | \(message)")
    fputs("\(ANSI.paint("Error:", ANSI.red)) \(message)\n", stderr)
    exit(1)
}

func usage() {
    print("""
    网络切换助手

    最简单的使用方式：直接运行 net，按数字选择操作。
    快捷命令：
      net 看         只看一次当前状态
      net 监看       持续显示状态
      net 清理       检查可清理的代理残留（不会直接清理）
      net 日志       查看最近 80 条操作与异常记录
      net clash日志  查看 Clash Verge 最近警告与错误
      net 日志目录   在 Finder 中打开日志目录
      net 诊断       生成不含账号和节点信息的脱敏报告
      net 模式       查看当前分流、兜底或直连模式
      net 分流       国内直连，海外经 Clash + Tailscale 私网 VPS
      net 兜底       所有公网流量临时改走 Tailscale Exit Node
      net 直连       取消代理，保留 Tailscale 私网连接
      net 网络诊断   比较默认路径与 Clash 代理路径

    危险操作确认统一支持 y/yes；命令行可使用 --yes，例如：net stop bywave --yes

    高级命令：mode status|split|fallback|direct、diagnose-network、status、watch、guard、start、stop、repair、install、uninstall
    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let safeAuditTokens = Set([
    "status", "看", "状态", "watch", "监看", "guard", "start", "stop", "repair", "清理",
    "日志", "clash日志", "日志目录", "诊断", "install", "uninstall", "help", "--help", "-h",
    "模式", "分流", "兜底", "直连", "网络诊断", "mode", "split", "fallback", "direct", "diagnose-network",
    "--yes", "--confirm", "v2rayn", "bywave", "clash", "powervpn", "viscosity", "hillstone", "tailscale"
])
let auditedArguments = arguments.map { safeAuditTokens.contains($0) ? $0 : "[参数已省略]" }
log("命令 | net\(auditedArguments.isEmpty ? "（交互菜单）" : " " + auditedArguments.joined(separator: " "))")
guard let command = arguments.first else { interactiveMenu() }
let options = Set(arguments.filter { $0.hasPrefix("--") })

switch command {
case "status", "看", "状态":
    log("操作 | 查看一次状态")
    printStatus(takeSnapshot())
case "watch", "监看": watch()
case "guard": guardLoop()
case "start":
    guard arguments.count >= 2, let client = Client(rawValue: arguments[1]) else { usage(); exit(1) }
    openClient(client)
case "stop":
    guard arguments.count >= 2, let client = Client(rawValue: arguments[1]) else { usage(); exit(1) }
    if !stopClient(client, options: options) { exit(1) }
case "repair", "清理":
    if !repair(options.contains("--yes") || options.contains("--confirm")) { exit(1) }
case "日志": showRecentLogs()
case "clash日志": showRecentClashLogs()
case "日志目录": openLogsDirectory()
case "诊断": _ = generateDiagnosticReport()
case "模式": printModeStatus()
case "分流":
    if !changeNetworkMode(.split, confirmed: options.contains("--yes")) { exit(1) }
case "兜底":
    if !changeNetworkMode(.fallback, confirmed: options.contains("--yes")) { exit(1) }
case "直连":
    if !changeNetworkMode(.direct, confirmed: options.contains("--yes")) { exit(1) }
case "mode":
    let action = arguments.dropFirst().first ?? "status"
    switch action {
    case "status": printModeStatus()
    case "split": if !changeNetworkMode(.split, confirmed: options.contains("--yes")) { exit(1) }
    case "fallback": if !changeNetworkMode(.fallback, confirmed: options.contains("--yes")) { exit(1) }
    case "direct": if !changeNetworkMode(.direct, confirmed: options.contains("--yes")) { exit(1) }
    default: usage(); exit(1)
    }
case "网络诊断", "diagnose-network": networkDiagnostic()
case "install": installAgent()
case "uninstall": uninstallAgent()
case "help", "--help", "-h": usage()
default: usage(); exit(1)
}
