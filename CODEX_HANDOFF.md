# ssh-xray-websocket — Codex handoff

## Scope and current state

Build a clean **v6** of the SSH/Xray/WebSocket AIO installer/menu. Do not continue layering repairs onto v5.x or deploy a fresh build to the production VPS until it has passed an end-to-end test on a fresh test VPS.

The active VPS discussed in the chat was `royal-mustang-20f` using `nl.vpnguruz.site`. It has been patched through v5.3. Reported state at that point:

| Area | Observed state |
|---|---|
| SSH WebSocket / SSH WebSocket TLS | Working |
| OpenVPN | Working (reported “100%”) |
| Hysteria 1 | Working |
| SSH direct and SSH-over-TLS direct | Not connecting / previously not genuinely implemented |
| Xray TLS and non-TLS | Not connecting in v5.x |
| Hysteria 2 | Daemon/UDP 443/certificate/auth health checks passed, but client connection failed |
| WireGuard | Not connecting in v5.x |

This is a design and implementation handoff, not evidence that every planned v6 route has been proven in production.

## Reference material (read-only)

Uploaded items from the prior chat:

- `ssh-xray-websocket-main(1).zip` — original installer; verified to advertise several ports that were not backed by listeners.
- `ssh-xray-websocket-multiprotocol-ports-updated(1).zip` and `ssh-xray-websocket-main.zip` — later project snapshots.
- `aio-multi-ip-xray-final-updated(2).sh` — AIO reference for menu/output behavior.
- `gf(1).sh` — reference implementation; its model informed the former Xray/SSLH fallback repair.
- `sshocean-edddyxx.conf` — WireGuard-output reference. Treat any keys in it as exposed; rotate real credentials rather than reusing them.

The current workspace’s `sources/` directory is empty; do not assume the source ZIPs are extracted here. Retrieve/copy the uploaded artifacts deliberately before implementation.

## Verified v5.x findings and bugs to avoid

- The original Nginx owned TCP 443 and proxied `/` to SSH WebSocket. It implemented **TLS → HTTP Upgrade → WebSocket → SSH**, not **TLS → raw SSH**. Its displayed SSL-direct ports (`443`, `8000`, `990`, and some WS ports) were partly misleading.
- Dropbear was actually configured on TCP `109` and `143`; the old “Dropbear 80” label represented a gateway, not a direct daemon listener.
- The original installer deleted/replaced `/etc/pam.d/common-password` from a remote source. Never restore that behavior. It contributed to `chpasswd`/`pam_chauthtok()` failures and incomplete SSH creation.
- v5.1 had Xray services sharing API port `10085`; unique management/API ports are required if services remain separate. v6 should preferably use one coherent Xray configuration.
- v5.1 failed to install/copy some account/link scripts, leading to missing output formatting.
- v5.x generated compacted Xray links; account output must preserve readable blank-line separation and complete parameters.
- Hysteria 2 server health was verified: service active, UDP 443 listening, certificate matched the domain, auth helper accepted a token, and UDP 443 bypassed catch-all DNAT. A failed client is therefore likely link/client/network-path related, not proof the server is down. Keep a compatibility test on UDP `36713` only while diagnosing; v6 target remains UDP `443`.
- WireGuard's `wireguard://` URI is convenience-only and not a standard. The generated `.conf` is authoritative. Do not require a PSK unless every generated client format carries it; re-import regenerated configs after any PSK policy change.
- UDP custom cannot literally own every UDP port first. Dedicated ports/ranges must take priority.

## v6 decisions (locked unless explicitly changed)

1. Remove **VMess** completely. Keep **VLESS** and **Trojan**. Trojan uses the primary VLESS TLS hostname/SNI and its own HTTP/WebSocket route, not a separate hostname.
2. Retain VLESS WS, XHTTP, HTTPUpgrade, and add VLESS TCP HTTP, gRPC, REALITY, and XTLS-Vision. Public non-TLS VLESS TCP/WS/HTTPUpgrade uses persistent **VLESS Encryption**, not `encryption=none`.
3. Preferred modern profile: **VLESS + REALITY + `xtls-rprx-vision`** on RAW/TCP. Do not implement gRPC + Vision.
4. Use one owner for public TCP 443: an L4 dispatcher (e.g. HAProxy). No Nginx, Stunnel, and Xray process may independently bind `0.0.0.0:443`.
5. UDP 443 is separate and remains Hysteria 2; TCP/UDP port numbers do not conflict.
6. Preserve the working OpenVPN and Hysteria 1 architectures. Do not redesign them while implementing the new front door.
7. Terminology is final: **SSH**, **SSH Payload**, **SSH WS NTLS**, **SSH SSL**, **SSH WS TLS**. Remove “SSH Direct” and remove “SSH SSL Payload” from menus/output. A WebSocket-upgrade payload over TLS is SSH WS TLS, not a separate SSL-payload mode.

## Target public protocol/port map

| Protocol | Public port(s) | Notes |
|---|---:|---|
| OpenSSH | TCP 22 | Raw SSH |
| Dropbear / SSH | TCP 109, 143 | Keep compatibility; display normal SSH as `22, 143` if desired |
| SSH Payload | TCP 80, 8080, 8880 | HTTP-like header stripped, then raw SSH to Dropbear |
| SSH WS NTLS | TCP 80, 8080, 8880, 2082, 2086 | HTTP Upgrade required |
| SSH SSL | TCP 443 | TLS then raw SSH, genuinely implement it |
| SSH WS TLS | TCP 443 | TLS then HTTP Upgrade/WebSocket |
| VLESS WS TLS / XHTTP TLS / HTTPUpgrade TLS / gRPC TLS | TCP 443 | Normal-domain TLS branch |
| VLESS encrypted NTLS (TCP HTTP / WS / HTTPUpgrade) | TCP 80, 8080, 8880 | `security=none`, with VLESS Encryption generated by `xray vlessenc`; dedicated paths only |
| VLESS REALITY + Vision | TCP 443 | L4 pass-through; Xray terminates REALITY |
| Trojan WS TLS | TCP 443 | Shared primary VLESS domain/SNI; dedicated HTTP/WebSocket path |
| VLESS TLS + Vision | TCP 443 | Dedicated SNI; L4 pass-through to Xray |
| OpenVPN | TCP/UDP 1194; TCP 8433; HTTP `80,8080,8880` `/openvpn` | Preserve working implementation |
| SlowDNS | UDP 53, 5300 | Preserve |
| WireGuard | UDP 4000 | Tunnel `10.0.0.0/24` |
| Hysteria 1 | UDP 20000–50000 → backend 36712 | Preserve working DNAT design |
| Hysteria 2 | UDP 443 | Separate from TCP 443 |
| ZiVPN | UDP 6000–19999 → backend 5667 | Preserve |
| UDP Custom | Remaining UDP → backend 36717 | Lowest routing priority |

UDP priority: 53/5300 SlowDNS; 443 Hysteria 2; 1194 OpenVPN; 4000 WireGuard; 6000–19999 ZiVPN; 20000–50000 Hysteria 1; all remaining ports UDP Custom. Document this honestly instead of claiming unqualified `1-65535` ownership.

## TCP 443 dispatcher design

Only the L4 dispatcher listens publicly on TCP 443. It inspects TLS ClientHello/SNI without terminating traffic where Xray must receive it untouched:

```text
TCP 443 (HAProxy/L4)
  ├─ REALITY configured SNI/target → Xray REALITY inbound (untouched)
  ├─ vision.<domain>              → Xray TLS + Vision (untouched)
  └─ main domain                  → TLS terminator / HTTP router
                                  ├─ raw decrypted SSH banner → Dropbear 143
                                  ├─ HTTP/2 gRPC service      → Xray gRPC localhost backend
                                  └─ HTTP/1.1 paths           → SSH WS / VLESS WS/XHTTP/HU / Trojan WS
```

Use `nl.vpnguruz.site` as the shared VLESS and Trojan hostname/SNI, plus `vision.nl.vpnguruz.site` (or equivalent configured name) for TLS Vision. All ordinary names resolve to the VPS. Wildcard DNS is acceptable. REALITY uses server-side REALITY names/target rather than the ordinary certificate hostname.

Suggested stable paths/service names (keep configurable but consistent): `/vltls`, `/vlntls`, `/vlxhttp`, `/vlhu`, and `/trojan`; service name `vlgrpc`; `/` is SSH WebSocket. Trojan has exactly one v6 route: `/trojan`. Do not expose either legacy route (`/trtls` or `/trntls`); regenerate Trojan links during migration. Route non-WebSocket HTTP-like traffic on the SSH public ports to the payload gateway, not to SSH WS.

### Xray detail

- Use one VLESS UUID per account across compatible inbounds; generate complete per-mode links.
- Generate a VLESS Encryption pair once with `xray vlessenc`, store the server decryption value in a root-readable `0600` file, and preserve it across installer reruns. Put its matching client encryption value in every encrypted-NTLS link. Never fall back silently to `encryption=none` on public NTLS listeners.
- REALITY server material is server-level: private key (never print), public key, short IDs, server names, target. Provide safe “REALITY Server Information” and a deliberate key-regeneration action that warns it invalidates existing profiles.
- Trojan is kept as **Trojan + WebSocket + TLS** on the primary domain/SNI. The TLS HTTP router sends its dedicated route (`/trojan`, or compatible `/trtls`) to a localhost Xray Trojan WS inbound. It is not a raw Trojan/TLS fallback branch.
- `vision.<domain>` remains a distinct SNI for VLESS TLS + XTLS-Vision, avoiding ambiguity with the shared primary TLS branch.
- gRPC is TLS + HTTP/2 and needs its correct server name/ALPN (`h2`); retain XHTTP as a primary modern HTTP transport.
- Do not terminate REALITY in the TLS terminator. Do not combine Vision with gRPC.

## Account-management requirements

- SSH accounts are standard Linux accounts: username, password, expiry. Use normal shadow/password tooling; never modify PAM. Make creation atomic with validation and rollback; deletion must show a numbered account list before selection.
- Xray menu: VLESS account management, Trojan account management, REALITY server info, service status/restart. No VMess menu/options/config/link output.
- VLESS account output: username/remark, UUID, expiry, separated complete links for every enabled mode. Include the matching VLESS Encryption value in encrypted-NTLS links and preserve readable spacing.
- Standard VLESS TLS and VLESS TLS + Vision links are generated from the VLESS account menu. Trojan remains a distinct account store/menu and generates Trojan WebSocket TLS links using the same primary VLESS hostname/SNI, port `443`, and its designated path.
- OpenVPN: retain existing create/renew/reset-password/delete/list/generator behavior; do not reintroduce profile-download requirements.
- Hysteria 1/2, ZiVPN, WireGuard: create/renew/delete/list/show details/link/config and expiry cleanup. WireGuard must show a valid `.conf`; optional custom endpoint host must resolve to the VPS before acceptance. Do not fake IPv6.
- Service/status output must report real public routes and internal backend ports separately.

## Exact implementation sequence

1. Extract and audit the reference ZIPs; inventory services, public listeners, account stores, systemd units, firewall/NAT rules, and menu entrypoints. Preserve an unmodified copy.
2. Establish a test VPS and an idempotent installer/upgrade strategy with backups, config validation, and rollback. Pin known-compatible binary versions during the test cycle.
3. Replace competing TCP 443 listeners with the L4 dispatcher and localhost backends. Implement and test its main-domain TLS termination, downstream SSH/HTTP classifier, HTTP/1.1 paths including Trojan WS, HTTP/2 gRPC route, and SNI pass-through routes before changing menus.
4. Implement the real SSH payload gateway and raw SSH-over-TLS route. Keep SSH WS behavior unchanged while distinguishing non-Upgrade payloads from WebSocket upgrades.
5. Consolidate Xray configuration: remove VMess; add VLESS WS/XHTTP/HU/gRPC, standard TLS, REALITY+Vision, TLS+Vision, and Trojan WS TLS. Route Trojan's dedicated WebSocket path to its localhost inbound; generate links from authoritative account stores.
6. Implement account/menu changes and accurate protocol labels/port displays.
7. Preserve and regression-test OpenVPN and Hysteria 1 unchanged. Then fix Hysteria 2 client-link generation and WireGuard configuration/output without broad routing changes.
8. Run the full verification checklist; only then use the clean installer on the production VPS.

## Verification checklist

- `bash -n`/shell checks; JSON validation; `systemctl` unit checks; `nginx -t`/HAProxy config checks; ensure exactly one TCP 443 listener.
- Confirm listener and firewall/NAT tables match the port map; specifically verify UDP-priority rules and that UDP 443 is not captured by catch-all DNAT.
- SSH: raw 22/143, payload 80/8080/8880, WS NTLS including 2082/2086, raw TLS 443, WS TLS 443; authenticate a newly created and renewed account; test deletion and expiry.
- Xray: fresh VLESS links for TCP HTTP TLS/encrypted-NTLS, WS TLS/encrypted-NTLS, XHTTP TLS, HTTPUpgrade TLS/encrypted-NTLS, gRPC TLS, standard TLS, REALITY+Vision, and TLS+Vision; fresh Trojan WS TLS link using the same primary VLESS hostname/SNI and its path; verify SNI/path/ALPN, encrypted-NTLS client compatibility, encryption-pair persistence across a rerun, and that VMess is absent.
- Confirm REALITY private key is never exposed and test the documented impact of rotating its server keys.
- OpenVPN: TCP, UDP, SSL 8433, and `/openvpn` BShield/HTTP routes must continue to connect exactly as before.
- Hysteria 1: public range routing/auth/obfs; Hysteria 2: actual client session on UDP 443 and, while diagnosing, optional 36713 compatibility path.
- WireGuard: import the newly generated `.conf`, check handshake and routed traffic; test custom endpoint only when DNS resolves to the VPS.
- SlowDNS, ZiVPN, UDP Custom, account expiry cleanup, restarts, backups, and an installer rerun must be tested.

## Cautions

- Do not change working OpenVPN or Hysteria 1 merely to fit the v6 architecture.
- Never let multiple processes bind public TCP 443. Do not describe a port as supported until an end-to-end client test passes.
- Treat uploaded/private configuration values as secrets. Do not copy their keys or tokens into fixtures, logs, docs, or generated example output.
- Make routing and account changes reversible; back up current production configuration before every migration.
