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
| CouchDB API   | `https://<TS_HOSTNAME>.<tailnet>.ts.net/couchdb/` |
| CouchDB admin (Fauxton) | `https://<TS_HOSTNAME>.<tailnet>.ts.net:8443/_utils/` |
| Drive (Nextcloud) — optional | `https://<TS_HOSTNAME>.<tailnet>.ts.net:9443/` |

> Fauxton is served on **port 8443** at the root, not under `/couchdb/`. Its bundle requests
> absolute paths like `/_all_dbs`, which under the `/couchdb/` prefix would be routed to
> FileBrowser instead. The REST API works fine under `/couchdb/` — that is the URI to give
> Obsidian LiveSync.

## Prepare the Pi

Before `install.sh` will succeed, the Pi has to satisfy a handful of assumptions that the
compose stack makes silently. This section explains what each one is and why it matters —
follow [docs/SETUP.md](docs/SETUP.md) for the long-form OS install, and use this page as the
checklist that gets you from "Pi boots" to "stack can start".

### What the stack assumes

| Requirement | Why it matters | Where it comes from |
|-------------|----------------|---------------------|
| 64-bit Raspberry Pi OS (`aarch64`) | `couchdb:3` and `filebrowser` are published for `linux/arm64`. On a 32-bit OS there is simply no image to pull. | `docker-compose.yml` images |
| Docker Engine + **Compose v2 plugin** | `install.sh` calls `docker compose` (the plugin), not the old `docker-compose` binary, and hard-fails if it is missing. | `scripts/install.sh` |
| `/dev/net/tun` present | The tailscale container bind-mounts the TUN device to bring up its WireGuard interface. Without it the container starts and never authenticates. | `docker-compose.yml` → `tailscale.volumes` |
| Data drive mounted at `DATA_PATH` | Every persistent path (`files`, `filebrowser`, `couchdb`) is a bind mount under `DATA_PATH`. The mounts use `create_host_path: false`, so a missing drive makes the stack refuse to start rather than quietly filling the OS drive. | `docker-compose.yml`, `.env` |
| `DATA_PATH` subdirs owned by `PUID:PGID` | FileBrowser and CouchDB write as that UID/GID. Root-owned directories produce permission errors on first write. | `.env`, `scripts/mount-drive.sh` |
| `$DATA_PATH/{files,filebrowser,couchdb}` exist | They are bind-mount sources with `create_host_path: false`. `install.sh` creates them; `mount-drive.sh` creates them too. | `docker-compose.yml`, `scripts/install.sh` |
| Accurate system clock | Tailscale provisions a real Let's Encrypt certificate. A skewed clock breaks TLS issuance and validation. | `config/tailscale/serve.json` |
| Tailscale account, reusable auth key, MagicDNS + HTTPS | The container authenticates non-interactively on first boot and serves on `<TS_HOSTNAME>.<TS_TAILNET>:443`. | `.env`, `serve.json` |

---

### 1. Verify the base OS

```bash
uname -m                # must print: aarch64
cat /etc/os-release     # Debian 12 (bookworm) or newer
free -h                 # 4 GB is enough; 8 GB if you plan to add more services
timedatectl             # "System clock synchronized: yes" — required for HTTPS certs
```

If the clock is not synchronised, fix that before anything else:

```bash
sudo timedatectl set-ntp true
```

Then get fully up to date and reboot:

```bash
sudo apt-get update && sudo apt-get full-upgrade -y
sudo reboot
```

---

### 2. Install Docker and the Compose plugin

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker            # apply the group without logging out

docker version           # daemon reachable without sudo
docker compose version   # must be v2.x — the plugin, not docker-compose
```

> `install.sh` refuses to run as root, and aborts if the Compose **plugin** is missing.
> If `docker compose version` fails, install it with
> `sudo apt-get install -y docker-compose-plugin`.

---

### 3. Load the TUN kernel module

Tailscale cannot create its WireGuard interface without `/dev/net/tun`. On Raspberry Pi OS
the module is usually present, but make it explicit and persistent across reboots:

```bash
ls -la /dev/net/tun || sudo modprobe tun
echo "tun" | sudo tee /etc/modules-load.d/tun.conf
```

---

### 4. Attach and mount the data drive

Plug the SSD into a **blue USB 3.0 port** (see [docs/HARDWARE.md](docs/HARDWARE.md)), then:

```bash
lsblk -f                          # identify the device, e.g. /dev/sda1
sudo bash scripts/mount-drive.sh  # optional ext4 format + UUID fstab entry + mount
```

The script mounts the drive at `/mnt/data`, creates `files/`, `filebrowser/` and `couchdb/`,
and chowns them to UID/GID `1000`. Confirm it really is a separate mount — `install.sh` only
warns here, and a missing mount means your data quietly lands on the OS drive:

```bash
mountpoint /mnt/data              # → /mnt/data is a mountpoint
df -h /mnt/data
```

---

### 5. Check the data layout

`mount-drive.sh` and `install.sh` both create and chown this layout, so there is normally
nothing to do here — just confirm it looks right:

```
/mnt/data/
├── files/          → FileBrowser root (/srv inside the container)
├── filebrowser/    → FileBrowser SQLite database (created on first start)
├── couchdb/        → CouchDB data files (owned by uid 5984)
├── couchdb-etc/    → staged CouchDB config, owned by uid 5984 (see below)
├── backups/        → nightly archives (mode 0700)
└── tmp/            → staging for backup/restore (never /tmp — that is a RAM tmpfs)
```

If you are creating it by hand:

```bash
sudo mkdir -p /mnt/data/{files,filebrowser,couchdb,backups,tmp}
sudo chown "$(id -u):$(id -g)" /mnt/data /mnt/data/{files,filebrowser,backups,tmp}
sudo chmod 700 /mnt/data/backups
```

### Why `couchdb-etc/` exists

CouchDB's config is **not** mounted from `config/couchdb/` in the repo. `install.sh` copies
it to `/mnt/data/couchdb-etc/` and chowns it to uid 5984 first, and compose mounts it from
there.

The reason is a sharp edge in the official image. Its entrypoint runs, under `set -e`:

```sh
find /opt/couchdb \! \( -user couchdb -group couchdb \) -exec chown -f couchdb:couchdb {} +
```

A file mounted from the repo is owned by *you*, not uid 5984, so `find` matches it and tries
to `chown` it — which fails on a read-only bind mount. `chown -f` suppresses the message but
not the exit status, `find` propagates it, and the entrypoint aborts **before CouchDB ever
starts**. The symptom is brutal to debug: the container exits instantly, `docker compose logs
couchdb` is completely empty, and the healthcheck just reports `restarting`.

Staging a copy that is already owned by 5984 means `find` never matches it, so there is
nothing to chown and nothing to fail.

**To change CouchDB settings**: edit `config/couchdb/zz-homedrive.ini` as usual, then re-run
`bash scripts/install.sh` (or `sudo cp` it into `/mnt/data/couchdb-etc/` and
`sudo chown 5984:5984` it) and `docker compose restart couchdb`. Editing the staged copy
directly works too, but the next `install.sh` run overwrites it.

`/mnt/data/couchdb` itself is chowned to 5984 by `install.sh` for the same reason.

---

### 6. Prepare Tailscale before first start

Do all of this in the [Tailscale admin console](https://login.tailscale.com/admin) *before*
starting the stack, so the container comes up already reachable over HTTPS:

1. **Sign in / create a tailnet** and note its name (e.g. `tail1234.ts.net`) → `TS_TAILNET`.
2. **DNS → enable MagicDNS.**
3. **DNS → HTTPS Certificates → Enable HTTPS.**
4. **Settings → Keys → Generate auth key**, tick **Reusable** so the container can
   re-authenticate after restarts → `TS_AUTHKEY`.
5. Install the Tailscale app on the phones and laptops that will use the drive.

---

### 7. Get the code and fill in `.env`

```bash
git clone https://github.com/<you>/home-services.git ~/home-services
cd ~/home-services/home-drive

cp .env.example .env
chmod 600 .env          # it holds your auth key and passwords
```

Find the UID/GID the containers should use:

```bash
id -u   # → PUID
id -g   # → PGID
```

Then edit `.env` and set at minimum:

| Variable | Value |
|----------|-------|
| `TS_AUTHKEY` | The reusable key from step 6 |
| `TS_HOSTNAME` | The Pi's tailnet name, e.g. `homepi` (no dots) |
| `TS_TAILNET` | Your tailnet, e.g. `tail1234.ts.net` |
| `COUCHDB_PASSWORD` | A strong password — `install.sh` rejects the placeholder value |
| `FILEBROWSER_ADMIN_PASSWORD` | A strong password — `install.sh` rejects the placeholder value |
| `DATA_PATH` | `/mnt/data` |
| `PUID` / `PGID` | Output of `id -u` / `id -g` |
| `TZ` | e.g. `Europe/London` |

`install.sh` applies `FILEBROWSER_ADMIN_USER` / `FILEBROWSER_ADMIN_PASSWORD` to the running
container on every run. FileBrowser seeds its own admin account with a well-known default
password on first start, which on a file server reachable by everyone on your tailnet is a
real hole — so the reset is not optional, and re-running `install.sh` is also how you
rotate that password later.

---

### 8. Optional but recommended hardening

```bash
sudo apt-get install -y ufw fail2ban

# Find YOUR LAN subnet first. Do not copy the example below verbatim — allowing
# the wrong subnet and then enabling ufw locks you out of SSH.
ip -br -4 addr show eth0        # e.g. 192.168.178.59/24 → use 192.168.178.0/24
LAN=192.168.178.0/24            # <- change this to match

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "$LAN" to any port 22 proto tcp   # LAN SSH only
sudo ufw enable
sudo systemctl enable --now fail2ban
```

> **Do not add `ufw allow in on tailscale0`.** In this stack Tailscale runs *inside a
> container*, so `tailscale0` exists only in that container's network namespace — there is no
> such interface on the host and the rule matches nothing. Tailnet traffic reaches the
> container as conntrack-established return traffic on the Docker bridge, which UFW already
> permits. That rule only makes sense in the host-Tailscale variant (approach B in
> [docs/TAILSCALE.md](docs/TAILSCALE.md)).

If you already added rules referring to `tailscale0` or the wrong subnet, list them by number
and delete them:

```bash
sudo ufw status numbered
sudo ufw delete <number>        # highest number first — deleting renumbers the rest
```

If you plan to use the nightly cron jobs further down this page, pre-create their log files
so a non-root crontab can write to them:

```bash
sudo touch /var/log/homedrive-backup.log /var/log/homedrive-health.log
sudo chown "$(id -u):$(id -g)" /var/log/homedrive-backup.log /var/log/homedrive-health.log
```

---

### 9. Preflight check

Run this from the project directory before `install.sh`. Every line should print `OK`:

```bash
cd ~/home-services/home-drive

[ "$(uname -m)" = "aarch64" ]     && echo "OK   64-bit OS"       || echo "FAIL 64-bit OS"
docker compose version >/dev/null 2>&1 && echo "OK   compose v2" || echo "FAIL compose v2"
docker info >/dev/null 2>&1       && echo "OK   docker w/o sudo" || echo "FAIL docker w/o sudo"
[ -e /dev/net/tun ]               && echo "OK   /dev/net/tun"    || echo "FAIL /dev/net/tun"
mountpoint -q /mnt/data           && echo "OK   drive mounted"   || echo "FAIL drive mounted"
[ -d /mnt/data/files ]            && echo "OK   files/"          || echo "FAIL files/"
[ -d /mnt/data/couchdb ]          && echo "OK   couchdb/"        || echo "FAIL couchdb/"
[ -d /mnt/data/filebrowser ]      && echo "OK   filebrowser/"    || echo "FAIL filebrowser/"
[ ! -d /mnt/data/filebrowser/filebrowser.db ] && echo "OK   no stray .db directory" || echo "FAIL filebrowser.db is a DIRECTORY - remove it"
[ -O /mnt/data ]                  && echo "OK   /mnt/data owned by me" || echo "FAIL /mnt/data ownership"
[ -f .env ]                       && echo "OK   .env present"    || echo "FAIL .env present"
timedatectl show -p NTPSynchronized --value | grep -q yes && echo "OK   clock synced" || echo "FAIL clock synced"
docker compose --env-file .env config >/dev/null 2>&1 && echo "OK   compose file valid" || echo "FAIL compose file valid"
```

Once every line reads `OK`, continue with the Quick Start below — steps 1–3 are already done,
so you can go straight to `bash scripts/install.sh`.

---

## Quick Start

> Assumes the Pi is already prepared — see [Prepare the Pi](#prepare-the-pi) above.

```bash
# 1. Clone
git clone https://github.com/<you>/home-services.git
cd home-services/home-drive

# 2. Copy and fill in environment variables
cp .env.example .env
chmod 600 .env
nano .env   # set TS_AUTHKEY, COUCHDB_PASSWORD, FILEBROWSER_ADMIN_PASSWORD, etc.

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

| Container   | Internal port | Bind address | Protocol |
|-------------|--------------|--------------|----------|
| filebrowser | 8080         | `127.0.0.1`  | HTTP     |
| couchdb     | 5984         | `127.0.0.1`  | HTTP     |

Both bind to loopback **inside the tailscale container's network namespace**. That is
reachable by `tailscale serve` but not from the tailnet IP directly, so clients cannot skip
the HTTPS proxy and speak plaintext HTTP to either service.

## Scheduled jobs

The health check installs itself as a systemd timer:

```bash
bash scripts/install-monitoring.sh
```

That runs the check every 15 minutes, puts `homedrive-health` and `homedrive-status` on
your `PATH`, and — if a screen is attached to the Pi — flashes the result onto it for five
seconds after each run. See [docs/MONITORING.md](docs/MONITORING.md).

The backup is still a crontab entry (`crontab -e`):

```cron
# Nightly backup at 02:30
30 2 * * * /home/pi/home-services/home-drive/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1
```

Prefer cron for the health check too? `bash scripts/install-monitoring.sh --cron` writes an
hourly entry and a logrotate rule instead of the timer.

## Security model

The tailnet is the trust boundary. Everything below assumes an attacker who is *not* on
your tailnet has no path in at all, and focuses on limiting the damage of the things that
can actually go wrong: a stolen laptop that is still logged into Tailscale, a backup
archive synced to someone else's cloud, or a compromised container.

| Control | What it does |
|---------|--------------|
| No published host ports | Nothing in the stack is reachable from the LAN or the internet. Every request arrives through `tailscale serve`. |
| Services bound to `127.0.0.1` | Inside the tailscale netns. Clients cannot bypass the HTTPS proxy and talk plaintext HTTP to FileBrowser or CouchDB over the tailnet IP. |
| php-fpm bound to `127.0.0.1:9000` | The drive's most important binding. Sharing the tailscale netns means the image default of `listen = 9000` would publish an unauthenticated FastCGI socket — remote code execution — to the whole tailnet. Overridden in `config/nextcloud/zz-listen.conf`. |
| PostgreSQL and Redis on loopback, Redis password-protected | Same reason. Set explicitly in `command:`, never left on the image default. |
| Nextcloud `trusted_proxies` | Without it every request appears to come from localhost, and the brute-force protection rate-limits all users together instead of the one guessing passwords. |
| `serve`, never `funnel` | Tailnet-only. Funnel (public internet exposure) is not configured anywhere and should not be. |
| CouchDB `require_valid_user = true` | Set in `[chttpd]`, where CouchDB 3 actually reads it. `/_up` is the only exemption, so the container healthcheck needs no credentials. |
| FileBrowser admin password forced from `.env` | `install.sh` resets it on every run instead of leaving FileBrowser's own default in place. |
| `.env` at mode 0600 | `install.sh` tightens it if you forget. It holds the tailnet auth key and both admin passwords. |
| Backups at mode 0600, `backups/` at 0700 | The archive contains every note in the vault as plaintext JSON. |
| `.env` excluded from backups | The archive can be pushed to third-party storage by rclone; secrets must not ride along. |
| Credentials off the command line | `backup.sh`, `restore.sh` and the monitoring library hand passwords to `curl` through a config file on stdin. `ps auxww` shows every argument of a `docker exec`, and these run every 15 minutes from a timer. |
| `no-new-privileges`, `cap_drop: ALL` | On FileBrowser and CouchDB. The tailscale container keeps `NET_ADMIN`/`NET_RAW` because it has to manage a WireGuard interface. |
| FileBrowser runs as `PUID:PGID` | Not root. The upstream image has no PUID/PGID handling, so this is set with compose's `user:`. |
| No shell or command execution in FileBrowser | `commands` and `shell` are empty in `settings.json`. |

### What this does *not* protect against

- Anyone with a device on your tailnet is inside the boundary. Use Tailscale ACLs if you
  share the tailnet with other people.
- CouchDB admin credentials are passed to the container as environment variables and are
  visible in `docker inspect` to anyone with Docker socket access — which on this box is
  root-equivalent anyway.
- End-to-end encryption of your notes is Obsidian LiveSync's passphrase, not this stack's.
  Set it, and the vault is unreadable even from a leaked backup archive.

---

## Troubleshooting

### Everything is healthy but nothing answers on port 443

Almost always a bad `serve.json`. `containerboot` expands **only** `${TS_CERT_DOMAIN}` in
that file — `${TS_HOSTNAME}`, `${TS_TAILNET}` and friends are passed through verbatim,
producing a serve config for a hostname that does not exist.

```bash
docker exec homedrive-tailscale tailscale serve status
docker exec homedrive-tailscale cat /config/tailscale/serve.json
```

The `serve status` output must show your real MagicDNS name, not a literal `${...}`.

### Image pull fails: `tls: bad record MAC`

A TLS record failed its integrity check, meaning bytes were corrupted between the registry
and the Pi. It is not a Docker or registry problem. On a Pi 5 the usual causes are, in order:

1. **NIC offload bugs** — payloads mangled after checksums are computed, so Ethernet CRC and
   TCP checksums never catch it. Test with
   `sudo ethtool -K eth0 tso off gso off gro off tx off rx off`, and persist with
   `sudo nmcli connection modify "Wired connection 1" ethtool.feature-tso off ethtool.feature-gso off ethtool.feature-gro off ethtool.feature-tx off ethtool.feature-rx off`.
2. **Under-voltage** — `vcgencmd get_throttled` must print `0x0`. A Pi 5 with a bus-powered
   SSD needs a real 5 V / 5 A supply.
3. **USB 3 interference with 2.4 GHz Wi-Fi** — only if you are on `wlan0`.

`install.sh` retries the pull three times, and if the registry is still unreachable but every
image is already on disk it continues with what it has rather than aborting. To skip the pull
entirely:

```bash
bash scripts/install.sh --skip-pull
```

### Stack refuses to start: "bind source path does not exist"

Working as intended. The bind mounts use `create_host_path: false`, so if the external
drive is not mounted Docker fails instead of silently creating the paths on the SD card and
writing your data there.

```bash
mountpoint /mnt/data      # the actual question
sudo mount -a
bash scripts/install.sh   # recreates the subdirectories once the drive is back
```

### FileBrowser fails to open its database

Check for a stray directory left by an older version of this stack, which bind-mounted
`filebrowser.db` as a *file*:

```bash
[ -d /mnt/data/filebrowser/filebrowser.db ] && sudo rmdir /mnt/data/filebrowser/filebrowser.db
```

`install.sh` removes it automatically if it is empty.

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
- Check `config/couchdb/zz-homedrive.ini` has the correct origins.
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
- [Obsidian sync](docs/OBSIDIAN.md) — seed device, second device, and troubleshooting
- [Backups](docs/BACKUP.md)
- [Monitoring](docs/MONITORING.md) — the health check, the status screen, and alerts
- [The drive](docs/DRIVE.md) — optional Nextcloud: sync clients, sharing, and how the file
  locking works

## Scripts

| Script | What it does |
|--------|--------------|
| `scripts/mount-drive.sh` | One-time: format and persistently mount the data drive |
| `scripts/install.sh` | Bring the stack up. Idempotent — re-run it after any config change |
| `scripts/install-drive.sh` | Install the optional Nextcloud drive: sync clients, sharing, file locking |
| `scripts/drive-autostart.sh` | Turn the drive's start-at-boot on or off, and check which it is |
| `scripts/install-monitoring.sh` | Install the health-check timer and the `homedrive-status` / `homedrive-health` commands |
| `scripts/health-dashboard.sh` | The status screen: storage breakdown, transfer rates, file activity, Pi temperature and load. Also draws on a screen attached to the Pi |
| `scripts/health-monitor.sh` | The unattended check: runs from a timer, quiet unless something is wrong, alerts via ntfy |
| `scripts/healthcheck.sh` | Compatibility shim — forwards to `health-monitor.sh` |
| `scripts/backup.sh` | Nightly CouchDB + FileBrowser backup |
| `scripts/restore.sh` | Restore from a backup archive |
| `scripts/obsidian-check.sh` | Is Obsidian LiveSync actually reaching CouchDB? Document count and recent changes |
