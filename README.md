# gost-gateway

Multi-VPS reverse proxy gateway. TLS-encrypted relay (`gost`) with strict IP-allowlist firewall and self-healing systemd persistence.

## What it sets up

- `gost` relay+tls listener on a configurable port (default `8443`)
- Self-signed 2048-bit TLS keypair, auto-regenerated if missing/corrupted
- Dedicated iptables chain `GOST_ACCESS_CONTROL` — only IPs in `/etc/gost/allowed_ips.txt` can reach the port, everything else dropped
- `allowed_ips.txt` synced to the firewall every 60s via cron (no restart needed to add/remove an IP)
- systemd service with `Restart=always` — auto-recovers from crash or reboot

## Requirements

- Debian/Ubuntu VPS, root access
- Outbound internet access (to fetch the `gost` binary from GitHub releases on first install)

## Install (new VPS)

Run as root, one command:

```bash
curl -fsSL https://raw.githubusercontent.com/mehedimhr/gost-gateway/main/install.sh | sudo bash -s -- 8443
```

Replace `8443` with any port you want (arg is optional, defaults to `8443`).

This installs all dependencies, the `gost` binary, TLS cert, systemd service, firewall sync script, and cron job — fully unattended.

## After install

1. Add allowed source IPs, one per line (or CIDR):
   ```bash
   sudo nano /etc/gost/allowed_ips.txt
   ```
   Changes apply automatically within 60 seconds — no restart needed.

2. Check status:
   ```bash
   sudo systemctl status gost-proxy
   sudo iptables -L GOST_ACCESS_CONTROL -n --line-numbers
   ```

3. Port/config locations:
   - Port: `/etc/gost/config.port`
   - Certs: `/etc/gost/certs/`
   - Allowlist: `/etc/gost/allowed_ips.txt`
   - Firewall sync log: `/var/log/gost-fw-sync.log`

## Notes

- `raw.githubusercontent.com` caches files for ~5 minutes after a push. If you just pushed a change, wait ~5 minutes before installing on a new VPS, otherwise it may fetch the stale version.
- Re-running `install.sh` is safe (idempotent) — won't duplicate firewall rules or break an existing install.
