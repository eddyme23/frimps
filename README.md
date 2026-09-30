
## Frimps fresh-server installation

Supported platform: a new **Debian 12** VPS, logged in as `root`.

Run this one command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eddyme23/frimps/main/install-frimps.sh)
```

The installer clones Frimps into `/root/frimps`, installs required system
packages and protocol binaries, issues a Cloudflare DNS-01 TLS certificate,
configures the selected protocol settings, and enables every Frimps-managed
service at boot. It asks for the primary domain, certificate names, Let's
Encrypt email, Cloudflare API token, SlowDNS nameserver, shared Hysteria 1 /
ZiVPN obfuscation, ZiVPN and Hysteria 2 passwords, REALITY settings, Vision
hostname, and BBR preference.

The Cloudflare token is deliberately visible while typed, as requested. Other
password inputs are hidden. The token is kept in a root-only Certbot renewal
credentials file so wildcard renewal can continue automatically.
