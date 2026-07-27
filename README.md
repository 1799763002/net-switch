# net-switch

`net-switch` is a macOS command-line assistant for safely switching between network clients. It observes client processes, selected local proxy settings, VPN service state, and `utun` routes; it helps the user exit a client cleanly before using another one.

[中文说明](README.zh-CN.md)

## What it does

- Provides a Chinese interactive terminal menu and short commands such as `net`, `net 看`, `net 日志`, and `net 诊断`.
- Detects v2rayN, Clash Verge, PowerVPN, Viscosity, Hillstone Secure Connect, and Tailscale using local process and platform state only.
- Protects an active v2rayN TUN connection: automatic cleanup is skipped and stopping it requires two explicit confirmations.
- Cleans only local HTTP/HTTPS/SOCKS proxy entries that point to `127.0.0.1:10808` or `127.0.0.1:7897`, and only after managed clients are inactive.
- Records local operation events and can generate a redacted diagnostic report.

It does not store or upload subscriptions, proxy nodes, passwords, VPN credentials, connection profiles, server addresses, DNS configuration, or complete route tables.

## Requirements

- macOS 13 or later
- Swift 6 toolchain
- The relevant client applications installed locally

The client mappings are intentionally conservative. `PowerVPN` uses a configured macOS VPN service named `小地球仪`; adjust the source before use if the service name or application bundle identifiers differ on your Mac.

## Run

From the project directory:

```bash
./net
```

The launcher builds a release binary on first use. To make `net` available from any terminal directory, add the project directory to `PATH` or place a small wrapper in a directory already on `PATH`.

Useful commands:

```bash
net              # interactive menu
net 看           # show the current state once
net 监看         # refresh the state every five seconds
net 清理         # inspect safe-to-clean local proxy residue
net 日志         # show recent events
net 日志目录     # open the local log directory in Finder
net 诊断         # create a redacted diagnostic report
```

Run tests with:

```bash
swift test
```

## Safety model

Use one network owner at a time. Before switching, disconnect in the original client, then use the interactive menu to request a normal exit. The tool never force-kills a client, deletes DNS settings, removes `utun` routes, or stops vendor background services.

Special handling:

- **v2rayN**: an active TUN route is protected. The tool will not automatically exit it or clear network settings.
- **Viscosity**: uses its AppleScript automation interface to disconnect connections before exiting.
- **PowerVPN**: refuses to exit while the configured macOS VPN service remains connected.
- **Hillstone Secure Connect**: uses redacted local lifecycle state to decide whether a connection is active; its vendor background service is never stopped.
- **Tailscale**: a stopped backend with no recognizable Tailscale route is treated as stopped even if a macOS network extension still appears attached.

## Logs and privacy

Logs are local under `~/Library/Logs/net-switch/` and are retained for 30 days. Event logs track actions, duration, redacted before/after state, refusal reasons, and errors. `launchd.log` may remain empty because events are written to `events-YYYY-MM-DD.log`.

`net 诊断` creates a redacted text report in the same directory. It reports only client names, high-level VPN state, proxy residue count, listening-port presence, guard state, and sanitized recent errors.

Do not commit generated logs, diagnostic reports, `.build/`, or local configuration. The included `.gitignore` excludes them.

## Contributing

Please open an issue with a redacted `net 诊断` report, the macOS version, the affected client version, and the exact menu action that produced the result. Never include VPN credentials, subscription URLs, private server addresses, or full system route output.

## License

[MIT](LICENSE)
