# Home Drive — Self-Hosted FileBrowser + Obsidian Sync on Raspberry Pi 5

A private, containerised home drive and shared Obsidian vault hosted on a Raspberry Pi 5.
**Nothing is exposed to the public internet.** All access is through a Tailscale tailnet
(WireGuard mesh VPN) using MagicDNS + Tailscale HTTPS certs.

## Architecture

```
  Phone / Laptop / Tablet
         │
    Tailscale App (WireGuard)
         │
    ─────────────────────────────────────
         │           Tailscale Tailnet
    ─────────────────────────────────────
         │
    Raspberry Pi 5  (Docker host)
    ┌────────────────────────────────────┐
    │  tailscale container               │
    │    ├─ MagicDNS: pi.<tailnet>.ts.net│
    │    └─ serve.json (HTTPS proxy)     │
    │         │                          │
    │  ┌──────┴───────────────────────┐  │
    │  │  filebrowser  (port 8080)    │  │
    │  │  couchdb      (port 5984)    │  │
    │  └──────────────────────────────┘  │
    │         │                          │
    │    External SSD (USB 3 / NVMe)     │
    │    /mnt/data/                      │
    └────────────────────────────────────┘
```

## URLs (after setup)

| Service       | URL                                          |
|---------------|----------------------------------------------|
| FileBrowser   | `https://<TS_HOSTNAME>.<tailnet>.ts.net/`    |
| CouchDB admin | `https://<TS_HOSTNAME>.<tailnet>.ts.net/couchdb/_utils/` |
| CouchDB API   | `https://<TS_HOSTNAME>.<tailnet>.ts.net/couchdb/` |

## Quick Start

```bash
# 1. Clone
git clone https://github.com/<you>/homedrive-pi.git
cd homedrive-pi

# 2. Copy and fill in environment variables
cp .env.example .env
nano .env   # set TS_AUTHKEY, COUCHDB_PASSWORD, FILEBROWSER_PASSWORD, etc.

# 3. Format + mount the external data drive
sudo bash scripts/mount-drive.sh

# 4. Install Docker (if not present) and bring up the stack
bash scripts/install.sh

# 5. Open the Tailscale admin console
#    - approve the new node
#    - enable MagicDNS and HTTPS (Machine settings → Enable HTTPS)

# 6. Open https://<TS_HOSTNAME>.<tailnet>.ts.net/  in your browser
```

## Ports (internal, not exposed to host)

All traffic enters through the **tailscale** container; no host ports are published.

| Container   | Internal port | Protocol |
|-------------|--------------|----------|
| filebrowser | 8080         | HTTP     |
| couchdb     | 5984         | HTTP     |

## Nightly Cron (add to host crontab with `crontab -e`)

```cron
# Nightly backup at 02:30
30 2 * * * /home/pi/homedrive-pi/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1

# Hourly health check
0 * * * * /home/pi/homedrive-pi/scripts/healthcheck.sh >> /var/log/homedrive-health.log 2>&1
```

## Troubleshooting

### TUN device not found
```bash
ls -la /dev/net/tun     # should exist
sudo modprobe tun       # load the module
echo "tun" | sudo tee /etc/modules-load.d/tun.conf  # persist across reboots
```

### MagicDNS / HTTPS cert not working
- In the Tailscale admin console → DNS → enable MagicDNS.
- Machines → click your Pi → enable HTTPS.
- Inside the container: `docker exec homedrive-tailscale tailscale cert <hostname>.<tailnet>.ts.net`

### CORS errors in Obsidian LiveSync
- Check `config/couchdb/local.ini` has the correct origins.
- Restart CouchDB: `docker compose restart couchdb`
- Verify: `curl -I https://<host>/couchdb/` — look for `Access-Control-Allow-Origin` header.

### External drive not mounting
```bash
lsblk -f                   # find the UUID
cat /etc/fstab             # verify the entry
sudo mount -a              # try mounting all fstab entries
journalctl -xe | grep mount  # check errors
```

### Container stays unhealthy
```bash
docker compose ps          # view status
docker compose logs tailscale
docker compose logs filebrowser
docker compose logs couchdb
```

## Docs

- [Hardware guide](docs/HARDWARE.md)
- [OS + Docker setup](docs/SETUP.md)
- [Tailscale integration](docs/TAILSCALE.md)
- [Obsidian sync](docs/OBSIDIAN.md)
- [Backups](docs/BACKUP.md)
