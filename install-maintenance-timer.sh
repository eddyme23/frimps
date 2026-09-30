#!/usr/bin/env bash
# Install the small, idempotent expiry sweep.  It only removes accounts whose
# recorded expiry date is before today; it never changes active accounts.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }

cat >/etc/systemd/system/frimps-account-cleanup.service <<'EOF'
[Unit]
Description=Frimps expired-account cleanup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/ssh-xray-websocket-v6/maintenance-v6.sh cleanup
EOF

cat >/etc/systemd/system/frimps-account-cleanup.timer <<'EOF'
[Unit]
Description=Daily Frimps expired-account cleanup

[Timer]
OnCalendar=*-*-* 03:17:00
Persistent=true
RandomizedDelaySec=10m
Unit=frimps-account-cleanup.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now frimps-account-cleanup.timer
echo 'Frimps expired-account cleanup is scheduled daily (with a small randomized delay).'
