# v6 foundation

This directory is the safe starting point for the v6 migration.  It is separate
from the legacy installer so it can be reviewed and tested on a fresh VPS before
it touches an existing installation.

## What this implements now

- A root-only v6 state directory at `/etc/ssh-xray-websocket-v6`.
- Pre-flight validation, timestamped backups, and a rollback manifest.
- A persistent VLESS Encryption pair for public non-TLS VLESS transports.
- A machine-readable route manifest: no VMess, one Trojan TLS WebSocket path
  (`/trojan`), and no legacy `/trtls` or `/trntls` routes.
- A validator which refuses an unsafe public non-TLS VLESS configuration.
- A renderer for localhost-only VLESS/Trojan backend inbounds and a route map
  that the future 443 dispatcher will consume.
- Staged HAProxy and Nginx routing configurations for TCP 443; these are not
  installed or enabled by the render step.
- A staged encrypted-NTLS Nginx front door on `80`, `8080`, and `8880` for
  VLESS TCP/WS/HTTPUpgrade plus the preserved `/openvpn` bridge.
- SSH-only non-TLS listeners on `2082` and `2086`; they expose no Xray or
  OpenVPN routes.
- A small Go TLS multiplexer for real SSH-over-TLS: `SSH-` streams go to
  Dropbear and HTTP/HTTP2 streams go to the loopback route router.
- A Go payload gateway: ordinary HTTP-like payloads are stripped before SSH;
  genuine WebSocket upgrades are forwarded to the existing WS backend.
- JSON-backed VLESS and Trojan account management with atomic store updates,
  expiry cleanup, and correct encrypted-NTLS link generation.
- A v6-managed Linux SSH account tool using normal shadow-password operations
  and expiry dates, without replacing or editing PAM configuration.
- A unified interactive v6 menu for SSH, VLESS, Trojan, REALITY information,
  and validation.
- Persistent REALITY keys and client-safe server information; the REALITY
  private key is never written to generated client output.
- A staged remaining-service foundation: an idempotent ordered UDP policy,
  baseline OpenVPN configurations, and non-destructive WireGuard bootstrap.
  Hysteria, ZiVPN, SlowDNS, and UDP-Custom remain disabled until their reviewed
  authenticated daemon configurations are supplied and client-tested.

## What deliberately comes next

The 443 dispatcher and the production Xray/Nginx/HAProxy units are not enabled
by this bootstrap. They require integration testing on a Linux VPS; this avoids
repeating the older installer behaviour of claiming working listeners before
they are proven.

## Test-VPS usage

```bash
cd ssh-xray-websocket-main
chmod +x v6/*.sh
sudo V6_DOMAIN=nl.vpnguruz.site ./v6/install-v6.sh
sudo ./v6/render-backends.sh
sudo ./v6/render-routing.sh
sudo ./v6/validate-v6.sh
sudo ./v6/stage-services.sh
sudo ./v6/preflight-cutover.sh
sudo ./v6/protocol-health-v6.sh --staged
sudo ./v6/migration-report.sh
sudo ./v6/udp-routing-audit.sh
sudo V6_DOMAIN=example.com ./v6/install-remaining-services.sh
```

After staging, test the private v6 backends without claiming public ports:

```bash
sudo ./v6/start-local-backends.sh
sudo ./v6/stop-local-backends.sh
```

After a reviewed test-VPS cutover, use `protocol-health-v6.sh --live` to
check listeners, v6 services, TLS, and retired Trojan-route responses.

## Test-VPS activation

This is deliberately guarded and must not be used as a production shortcut.
After manually releasing TCP 443 from the legacy stack on a fresh test VPS:

```bash
sudo V6_CONFIRM_TEST_VPS=YES ./v6/activate-test-vps.sh
sudo ./v6/protocol-health-v6.sh --live
```

The script never stops legacy services. It refuses to run while TCP 443 has an
owner and backs up the active proxy files before installing test-VPS routing.

To reverse that test activation using its recorded proxy backup:

```bash
sudo V6_CONFIRM_TEST_VPS=YES ./v6/rollback-test-vps.sh
```

Staging validates and installs v6 files under `/etc/ssh-xray-websocket-v6` but
does **not** start a service, replace an Nginx configuration, or take TCP 443.
The preflight deliberately fails while the legacy stack owns TCP 443.

Staging also installs a stable menu command:

```bash
sudo ssh-xray-websocket-v6-menu
```

## Account commands

```bash
sudo ./v6/accounts.sh vless create alice 30
sudo ./v6/accounts.sh vless links alice
sudo ./v6/accounts.sh trojan create bob 30
sudo ./v6/accounts.sh trojan links bob
sudo V6_REALITY_TARGET=www.example.com:443 V6_REALITY_SERVER_NAME=www.example.com ./v6/generate-reality-keys.sh
sudo ./v6/ssh-accounts.sh create alice 30
sudo ./v6/ssh-accounts.sh choose-delete
sudo ./v6/menu-v6.sh
```

## Controlled legacy account import

On a test VPS, preserve a legacy VLESS UUID or Trojan password only after
choosing the correct expiry date. Existing v6 names are never overwritten.

```bash
sudo ./v6/import-legacy-accounts.sh vless /usr/local/etc/xray/vltls.json 2027-01-31
sudo ./v6/import-legacy-accounts.sh trojan /usr/local/etc/xray/trtls.json 2027-01-31
```

`install-v6.sh` must be run only on a test VPS for now. It backs up relevant
configuration and writes v6 state, but does not restart or replace legacy
services.

For the full staged test-VPS preparation, after installing the dependencies
(`jq`, `xray`, `haproxy`, `nginx`, `go`, and `openssl`), use:

```bash
sudo V6_DOMAIN=nl.vpnguruz.site ./v6/install-test-vps.sh
```
