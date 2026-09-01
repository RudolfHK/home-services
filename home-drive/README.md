# Home Drive: Self-Hosted Nextcloud on Raspberry Pi 5

Google-Drive-style storage on your own hardware: browse and edit in a browser, sync clients
on desktop and mobile, users and sharing, and file locking, so two people can't write the
same file at the same time. Reachable directly on your LAN by default, with an optional
Tailscale profile to reach it from outside the LAN as well.

## Architecture

```
  Reachable two ways, either or both at once:

  Phone / Laptop / Tablet, on the LAN                Phone / Laptop, off the LAN
         │                                                    │
    http://<LAN host>:<NEXTCLOUD_PORT>/               Tailscale App (WireGuard)
         │                                                    │
         │                                        ─────────────────────────
         │                                             Tailscale Tailnet
         │                                        ─────────────────────────
         │                                                    │
    Raspberry Pi 5  (Docker host)                             │
    ┌───────────────────────────────────────────────────────────────────┐
    │                                                                   │
    │  nextcloud-web (nginx, port ${NEXTCLOUD_PORT}) ◄──────── tailscale │
    │         │                                       (optional profile)│
    │  nextcloud-app (php-fpm)                                          │
    │         │                                                         │
    │  nextcloud-db (PostgreSQL)   nextcloud-redis (locking)            │
    │         │                                                         │
    │    External SSD (USB 3 / NVMe)                                   │
    │    ${DATA_PATH}/nextcloud/                                        │
    └───────────────────────────────────────────────────────────────────┘
```

Every container talks to every other one over one internal Docker network with a fixed
subnet (`homedrive_net`, `10.89.0.0/24`). Only `nextcloud-web` publishes a host port; nothing
else is reachable except through it, on the LAN or (if enabled) via `tailscale serve`.

## URLs (after setup)

| Access | URL |
|--------|-----|
| LAN (always available) | `http://${NEXTCLOUD_LAN_HOSTNAME}:${NEXTCLOUD_PORT}/` |
| Tailscale (optional profile) | `https://${TS_HOSTNAME}.${TS_TAILNET}/` |

## Why LAN-direct, with Tailscale as an add-on

This mirrors PiHub's networking in the rest of this repo: a service that's fully usable at
home with zero extra setup, and an opt-in profile for reaching it from anywhere once you
need that. Concretely:

- **Nextcloud has its own authentication and per-user accounts.** Unlike a raw admin panel,
  putting it directly on the LAN doesn't hand out anything an attacker on your Wi-Fi
  couldn't already try to log into; there's no unauthenticated surface being newly exposed.
- **A tag-approved Tailscale device works the same everywhere.** Tailscale has no concept of
  "this device is currently on the LAN" versus "currently remote"; once a device is
  tag-approved it can reach the tailnet the same way from either place. So "confined to LAN
  and tailnet by default, with tag-approved devices able to reach it from outside the LAN
  too" collapses to one design: publish on the LAN, and let the optional `tailscale` profile
  cover the "from outside the LAN" case for approved devices, exactly like PiHub already
  does for the rest of this repo's services.

## Prepare the Pi

Before `install.sh` will succeed, the Pi has to satisfy a handful of assumptions that the
compose stack makes silently. This section explains what each one is and why it matters.
For the long-form OS install, follow [docs/SETUP.md](docs/SETUP.md); use this page as the
checklist that gets you from "Pi boots" to "stack can start".

### What the stack assumes

| Requirement | Why it matters | Where it comes from |
|-------------|----------------|---------------------|
| 64-bit Raspberry Pi OS (`aarch64`) | Nextcloud, PostgreSQL and Redis are all published for `linux/arm64`. On a 32-bit OS there is simply no image to pull. | `docker-compose.yml` images |
| Docker Engine + **Compose v2 plugin** | `install.sh` calls `docker compose` (the plugin), not the old `docker-compose` binary, and hard-fails if it is missing. | `scripts/install.sh` |
| Data drive mounted at `DATA_PATH` | Every persistent path (`data`, `config`, `db`, `redis`) is a bind mount under `DATA_PATH`. The mounts use `create_host_path: false`, so a missing drive makes the stack refuse to start rather than quietly filling the OS drive. | `docker-compose.yml`, `.env` |
| `$DATA_PATH/nextcloud/*` owned by the right uid | Nextcloud, PostgreSQL and Redis each run as a different uid inside their own image. `install.sh` resolves each one and chowns accordingly; a root-owned directory produces permission errors on first write. | `scripts/install.sh` |
| Accurate system clock | Needed for TLS certificate validation, whether that's Nextcloud's own or (if the `tailscale` profile is used) Tailscale's. A skewed clock breaks both issuance and validation. | general |
| `/dev/net/tun` present (only if using the `tailscale` profile) | The optional tailscale container bind-mounts the TUN device to bring up its WireGuard interface. Without it the container starts and never authenticates. Not needed for LAN-only use. | `docker-compose.yml` → `tailscale.volumes` |

---

### 1. Verify the base OS

```bash
uname -m                # must print: aarch64
cat /etc/os-release     # Debian 12 (bookworm) or newer
free -h                 # 4 GB is enough; 8 GB if you plan to add more services
timedatectl             # "System clock synchronized: yes"
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
docker compose version   # must be v2.x, the plugin, not docker-compose
```

> `install.sh` refuses to run as root, and aborts if the Compose **plugin** is missing.
> If `docker compose version` fails, install it with
> `sudo apt-get install -y docker-compose-plugin`.

---

### 3. Attach and mount the data drive

Plug the SSD into a **blue USB 3.0 port** (see [docs/HARDWARE.md](docs/HARDWARE.md)), then:

```bash
lsblk -f                          # identify the device, e.g. /dev/sda1
sudo bash scripts/mount-drive.sh  # optional ext4 format + UUID fstab entry + mount
```

Confirm it really is a separate mount. `install.sh` only warns if it isn't, and a missing
mount means your data quietly lands on the OS drive:

```bash
mountpoint /mnt/data              # → /mnt/data is a mountpoint
df -h /mnt/data
```

`install.sh` creates and owns the `nextcloud/{data,config,db,redis}` tree itself, resolving
each container's actual uid rather than assuming one, so there's normally nothing to do here
beyond mounting the drive.

---

### 4. (Optional) Load the TUN kernel module

Only needed if you plan to enable the `tailscale` profile. Tailscale cannot create its
WireGuard interface without `/dev/net/tun`. On Raspberry Pi OS the module is usually
present, but make it explicit and persistent across reboots:

```bash
ls -la /dev/net/tun || sudo modprobe tun
echo "tun" | sudo tee /etc/modules-load.d/tun.conf
```

---

### 5. Get the code and fill in `.env`

```bash
git clone https://github.com/<you>/home-services.git ~/home-services
cd ~/home-services/home-drive

cp .env.example .env
chmod 600 .env          # it holds your database and admin passwords
```

Find the UID/GID the containers should use:

```bash
id -u   # → PUID
id -g   # → PGID
```

Then edit `.env` and set at minimum:

| Variable | Value |
|----------|-------|
| `NEXTCLOUD_LAN_HOSTNAME` | How devices on the LAN reach this box, e.g. `homepi.local` or a static IP |
| `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` | The first admin account (`install.sh` rejects the placeholder value) |
| `NEXTCLOUD_DB_PASSWORD` | A strong, random password: `openssl rand -base64 32` |
| `NEXTCLOUD_REDIS_PASSWORD` | Same: `openssl rand -base64 32` |
| `DATA_PATH` | `/mnt/data` |
| `PUID` / `PGID` | Output of `id -u` / `id -g` |
| `TZ` | e.g. `Europe/London` |

Leave the `TS_*` variables empty unless you're also enabling the optional Tailscale
profile (see below).

---

### 6. Optional but recommended hardening

```bash
sudo apt-get install -y ufw fail2ban

# Find YOUR LAN subnet first. Do not copy the example below verbatim; allowing
# the wrong subnet and then enabling ufw locks you out of SSH.
ip -br -4 addr show eth0        # e.g. 192.168.178.59/24 → use 192.168.178.0/24
LAN=192.168.178.0/24            # <- change this to match

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from "$LAN" to any port 22 proto tcp     # LAN SSH only
sudo ufw allow from "$LAN" to any port "${NEXTCLOUD_PORT:-80}" proto tcp
sudo ufw enable
sudo systemctl enable --now fail2ban
```

> **If you also enable the `tailscale` profile, do not add
> `ufw allow in on tailscale0`.** In this stack Tailscale runs *inside a container*, so
> `tailscale0` exists only in that container's network namespace. There's no such interface
> on the host, and the rule matches nothing. Tailnet traffic reaches the container as
> conntrack-established return traffic on the Docker bridge, which UFW already permits.

If you plan to use the nightly backup cron job further down this page, pre-create its log
file so a non-root crontab can write to it:

```bash
sudo touch /var/log/homedrive-backup.log
sudo chown "$(id -u):$(id -g)" /var/log/homedrive-backup.log
```

---

### 7. Preflight check

Run this from the project directory before `install.sh`. Every line should print `OK`:

```bash
cd ~/home-services/home-drive

[ "$(uname -m)" = "aarch64" ]     && echo "OK   64-bit OS"       || echo "FAIL 64-bit OS"
docker compose version >/dev/null 2>&1 && echo "OK   compose v2" || echo "FAIL compose v2"
docker info >/dev/null 2>&1       && echo "OK   docker w/o sudo" || echo "FAIL docker w/o sudo"
mountpoint -q /mnt/data           && echo "OK   drive mounted"   || echo "FAIL drive mounted"
[ -O /mnt/data ]                  && echo "OK   /mnt/data owned by me" || echo "FAIL /mnt/data ownership"
[ -f .env ]                       && echo "OK   .env present"    || echo "FAIL .env present"
timedatectl show -p NTPSynchronized --value | grep -q yes && echo "OK   clock synced" || echo "FAIL clock synced"
docker compose --env-file .env config >/dev/null 2>&1 && echo "OK   compose file valid" || echo "FAIL compose file valid"
```

Once every line reads `OK`, continue with the Quick Start below.

---

## Quick Start

> Assumes the Pi is already prepared. See [Prepare the Pi](#prepare-the-pi) above.

```bash
# 1. Clone
git clone https://github.com/<you>/home-services.git
cd home-services/home-drive

# 2. Copy and fill in environment variables
cp .env.example .env
chmod 600 .env
nano .env   # set NEXTCLOUD_LAN_HOSTNAME, NEXTCLOUD_ADMIN_PASSWORD, etc.

# 3. Format + mount the external data drive
sudo bash scripts/mount-drive.sh

# 4. Install Docker (if not present) and bring up the stack
bash scripts/install.sh

# 5. Open http://<NEXTCLOUD_LAN_HOSTNAME>:<NEXTCLOUD_PORT>/ in your browser
```

## Enabling remote access over Tailscale (optional)

Do this only if you also want the drive reachable from outside the LAN, from a device
already approved on your tailnet.

1. Apply [`../tailscale/acl-policy.hujson`](../tailscale/acl-policy.hujson) to your tailnet
   and onboard your device per
   [`../tailscale/docs/DEVICE-ONBOARDING.md`](../tailscale/docs/DEVICE-ONBOARDING.md), if you
   haven't already for another service in this repo.
2. In the [Tailscale admin console](https://login.tailscale.com/admin):
   - **DNS → enable MagicDNS.**
   - **DNS → HTTPS Certificates → Enable HTTPS.**
   - **Settings → Keys → Generate auth key.** Prefer a short-lived, non-reusable key; see the
     comment above `TS_AUTHKEY` in `.env.example` for why that's enough.
3. Fill in `TS_AUTHKEY`, `TS_HOSTNAME`, `TS_TAILNET` and `TS_EXTRA_ARGS` in `.env`.
4. Start the profile:
   ```bash
   docker compose --profile tailscale up -d
   ```
5. Open `https://${TS_HOSTNAME}.${TS_TAILNET}/` from the approved device.

See [`tailscale/README.md`](tailscale/README.md) for how `serve.json` and the nginx
protocol-detection logic fit together, and troubleshooting below if port 443 doesn't answer.

## Ports

| Container | Port | Reachable from |
|-----------|------|-----------------|
| `nextcloud-web` (nginx) | `${NEXTCLOUD_PORT}` (default `80`) | LAN, always |
| `tailscale` (optional profile) | `443` | Tailnet, only if the `tailscale` profile is running; proxies to `nextcloud-web` |

Every other container (`nextcloud-app`, `nextcloud-db`, `nextcloud-redis`, `nextcloud-cron`)
publishes nothing; they're reachable only from other containers on `homedrive_net`.

## Clients

Install the official Nextcloud clients and point them at your chosen URL from the table
above:

- **Desktop** (Windows/macOS/Linux): full two-way sync of selected folders, or Virtual Files
  mode where nothing is downloaded until opened.
- **Android / iOS**: browse, auto-upload photos, make files available offline.
- **Anything WebDAV**: `<url>/remote.php/dav/files/<user>/` works in Windows Explorer, macOS
  Finder, Nautilus, and rclone.

**Use an app password per device**, not your login: Personal settings → Security → Devices &
sessions → Create new app password. A lost phone is then revoked with one click and can't be
used to change your password or read your sessions.

## How the corruption protection actually works

Three separate mechanisms handle this, and it's worth knowing which one does what, since
they fail differently.

### 1. Transactional file locking, automatic

Every write takes a short-lived lock in Redis first. A second client trying to write the
same file gets `423 Locked` and retries, instead of interleaving its bytes with the first
writer's. **This is the thing that prevents corruption.** It's always on, and you never see
it unless two clients genuinely collide.

It needs shared, fast, atomic storage, which is why there's a Redis container:
`'filelocking.enabled' => true` with `memcache.locking` pointed at Redis in
[zz-homedrive.config.php](config/nextcloud/zz-homedrive.config.php).

Locks expire after 15 minutes (`filelocking.ttl`) so a client that dies mid-write can't block
a file forever. The `nextcloud-cron` container is what actually clears them, which is why
that container isn't optional either.

### 2. Exclusive locks, deliberate and user-visible

The `files_lock` app, installed by `install.sh`. Right-click a file → **Lock file**. While
locked:

- everyone else sees it as read-only, with your name and the time,
- the desktop clients refuse to upload changes to it,
- WebDAV clients (Word, Excel, LibreOffice over a mounted drive) take and release these
  locks *automatically* when they open and close a document.

This is the answer to "two people must not edit the same file at once" in the workflow
sense. Unlock manually, or let it expire; a lock a user forgot about doesn't become
permanent.

### 3. Versions and trash: the recovery net

Locking prevents the collision; versions save you when something goes wrong anyway. Every
change keeps a version (90 days) and deleted files sit in the trash (30 days), both set to
`auto` so Nextcloud shrinks them rather than filling the drive.

Right-click → Versions → Restore.

### What none of it protects against

- **Two people editing the same file on purpose, sequentially.** The second person's save
  wins, and the first version is in the version history. Locking is advisory in the sense
  that a user can always unlock.
- **A file edited outside Nextcloud.** See the next section.
- **Bit rot on the drive itself.** That's what SMART monitoring and backups are for.

## The one rule: nothing else writes into the drive without telling Nextcloud

Nextcloud keeps an index of every file in its database. Write into
`${DATA_PATH}/nextcloud/data/` from outside (a shell, rsync) and Nextcloud has no idea the
file exists. Worse, it may overwrite it later, because as far as it's concerned that name
is free.

This matters beyond this stack: elsewhere in this repo, PiHub can be pointed at a folder
inside this Nextcloud data directory as its media library (see `pihub/README.md`'s
"Mounting a Nextcloud folder as your media library"), and PiHub's own auto-download feature
writes new files into it directly. Any process that writes into `nextcloud/data/` from
outside Nextcloud, PiHub included, needs Nextcloud told about it afterwards:

```bash
docker exec -u www-data homedrive-nextcloud-app php occ files:scan --all
```

Want a non-Nextcloud folder visible inside the drive as well? Do it properly, through
**Settings → Administration → External storage** as a *Local* mount. Nextcloud then knows
it's external and rescans it, but locking and versioning do **not** apply there, so treat it
as a viewing convenience, not a place to collaborate.

## Operating it

### Starting and stopping

```bash
docker compose ps              # all five containers (plus tailscale, if that profile is on)
docker compose stop            # stop, keep them
docker compose down            # stop and remove
docker compose up -d           # bring the stack back
```

### Autostart at boot

`install.sh` installs and enables `homedrive.service`, so the stack comes back after every
reboot. The switch:

```bash
bash scripts/autostart.sh status   # is it on? is it running?
bash scripts/autostart.sh on
bash scripts/autostart.sh off
```

(`systemctl enable/disable homedrive` does the same thing; the script exists so that `off`
also stops the containers, which matters for the reason explained below.)

**Why a systemd unit when every container already has `restart: unless-stopped`?** Because
that policy covers less than it appears to:

| Situation | `restart: unless-stopped` | The unit |
|---|---|---|
| A container crashes while the Pi is running | restarts it | not involved |
| Reboot, containers still exist | restores them | also fine |
| Reboot after `docker compose down` | nothing exists to restore | recreates them |
| **Docker starts before the USB drive mounts** | five failed containers | waits |

That last row is the one that actually bites on a Pi. Every container binds a path under
`${DATA_PATH}` with `create_host_path: false`, so if Docker wins the race against the
external drive they all fail to start and simply stay dead. A restart policy has no way to
express "wait for that filesystem," so the unit declares `RequiresMountsFor=${DATA_PATH}`
and the script additionally waits (up to `DRIVE_MOUNT_WAIT`, default 180s) for the bind-mount
directories to appear before calling `docker compose up -d`.

So the two mechanisms split the job: **systemd owns starting the stack at boot, Docker's
restart policy owns recovering it from a crash while the machine is running.**

**Why `off` also stops the containers.** `unless-stopped` restores any container that was
*running* when the daemon last stopped. Disabling the boot unit while leaving the stack up
would therefore still bring it back at the next boot, and the switch would look broken.
`autostart.sh off` (and `systemctl disable --now`) stops them, which is what makes the
setting stick.

### occ

```bash
# The occ admin command, for everything below
alias occ='docker exec -u www-data homedrive-nextcloud-app php /var/www/html/occ'

occ status                       # installed? maintenance? version?
occ user:list
occ files:scan --all             # after adding files from outside
occ maintenance:mode --off       # if a backup was interrupted
occ app:list                     # is files_lock enabled?
occ config:list system           # effective configuration
```

### Upgrades

```bash
docker compose pull
docker compose up -d
docker exec -u www-data homedrive-nextcloud-app php occ upgrade   # if asked to
```

Never skip a major version. Nextcloud only supports one-major-at-a-time upgrades. Pin
`NEXTCLOUD_TAG` in `.env` once the stack works, and step it deliberately.

## Scheduled jobs

Backups are a crontab entry (`crontab -e`):

```cron
# Nightly backup at 02:30
30 2 * * * /home/pi/home-services/home-drive/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1
```

See [docs/BACKUP.md](docs/BACKUP.md) for what's included, restore procedures, and off-Pi
copies with rclone.

## Security model

Everything below assumes the LAN itself is reasonably trusted (the usual case for a home
network), and focuses on limiting what's exposed beyond it and the damage of the things that
can actually go wrong: a stolen laptop still logged into a sync client, a backup archive
synced to someone else's cloud, or a compromised container.

| Control | What it does |
|---------|--------------|
| Only `nextcloud-web` publishes a port | `nextcloud-app` (php-fpm), `nextcloud-db` and `nextcloud-redis` are reachable only from other containers on `homedrive_net`, never from the LAN or a host process. |
| Fixed compose subnet (`10.89.0.0/24`) | Lets `trusted_proxies` name a stable CIDR instead of Compose's non-deterministic auto-assigned one, so it doesn't silently stop matching after a stack rebuild. |
| Redis password-protected | Set explicitly in `command:`, never left on the image default. |
| Nextcloud `trusted_proxies` | Without it every request appears to come from nginx's own container address, and the brute-force protection would rate-limit all users together instead of the one guessing passwords. |
| No `OVERWRITEPROTOCOL`/`OVERWRITEHOST` | Nextcloud detects scheme and host per request from the trusted-proxy headers instead, which is what makes plain-HTTP LAN access and HTTPS-via-`tailscale serve` both work correctly at the same time. |
| `serve`, never `funnel` (Tailscale profile) | Tailnet-only. Funnel (public internet exposure) is not configured anywhere and should not be. |
| `.env` at mode 0600 | `install.sh` tightens it if you forget. It holds the admin, database and Redis passwords. |
| Backups at mode 0600, `backups/` at 0700 | The archive contains a full database dump. |
| `.env` excluded from backups | The archive can be pushed to third-party storage by rclone; secrets must not ride along. |
| Credentials off the command line | `backup.sh` and `restore.sh` hand the database password to `psql`/`pg_dump` through the container's stdin, never as a `docker exec` argument. `ps auxww` shows every argument of a `docker exec`. |
| `no-new-privileges`, `cap_drop: ALL` | On every Nextcloud-stack container. The optional tailscale container keeps `NET_ADMIN`/`NET_RAW` because it has to manage a WireGuard interface. |

### What this does *not* protect against

- Anyone with access to your LAN can reach Nextcloud's login page. Its own account
  authentication (and two-factor, if you enable it) is the barrier at that point, same as
  any self-hosted app on a home network.
- Anyone with a tailnet device tagged `tag:approved-device` (if you enable the Tailscale
  profile) is inside that boundary too. Use Tailscale ACLs if you share the tailnet with
  other people; see `../tailscale/README.md`.
- Nextcloud's database credentials are passed to the container as environment variables and
  are visible in `docker inspect` to anyone with Docker socket access, which on this box is
  root-equivalent anyway.

## Resource cost on a Pi 5

Roughly 900 MB of RAM for the five containers at idle, comfortable on a 4 GB Pi 5 with an
SSD. Two things to watch:

- **Previews** are the most expensive thing Nextcloud does. The config caps them at
  1024x1024 and trims the provider list to images and audio; the default list spawns
  external binaries for office documents and video.
- **The database on an SD card** will be the bottleneck and will wear the card out. If the
  OS is on microSD, this is the argument for the NVMe HAT in
  [docs/HARDWARE.md](docs/HARDWARE.md).

---

## Troubleshooting

### Stack refuses to start: "bind source path does not exist"

Working as intended. The bind mounts use `create_host_path: false`, so if the external
drive is not mounted Docker fails instead of silently creating the paths on the SD card and
writing your data there.

```bash
mountpoint /mnt/data      # the actual question
sudo mount -a
bash scripts/install.sh   # recreates the subdirectories once the drive is back
```

### Nothing answers on the LAN port

```bash
docker compose ps                  # is nextcloud-web running and healthy?
curl -I http://localhost:${NEXTCLOUD_PORT:-80}/
```

If `nextcloud-web` shows healthy but nothing answers, check `NEXTCLOUD_PORT` in `.env`
actually matches what you're requesting, and that a firewall rule (step 6 above) isn't
blocking it from the device you're testing on.

### `install.sh` times out and `status.php` answers 500 forever

Symptom — `install.sh` gives up with *"Nextcloud did not report 'installed: true' within
10 minutes"*, and `docker compose logs nextcloud-app` is nothing but:

```
Warning: /var/www/html/config/apcu.config.php differs from the latest version of this image …
Warning: /var/www/html/config/apps.config.php differs from the latest version of this image …
…
10.89.0.6 - "GET /status.php" 500
```

Those warnings mean the files are **missing**, not edited — the image's check is a `cmp`
against a file that isn't there. The image only unpacks its own config files while
`/var/www/html/config` is still empty:

```sh
for dir in config data custom_apps themes; do
  if [ ! -d "/var/www/html/$dir" ] || directory_empty "/var/www/html/$dir"; then
    rsync … /usr/src/nextcloud/ /var/www/html/
  fi
done                                            # the image's docker-entrypoint.sh
```

Anything already sitting in `$DATA_PATH/nextcloud/config` at first start — including a
pre-staged `zz-homedrive.config.php` — makes that test false. Nextcloud then boots without
`apps.config.php`, `redis.config.php` and the rest, and 500s on every request. Worse, the
same pass writes `version.php`, and its presence is what tells the entrypoint there is
nothing to install, so no later start ever retries.

`install.sh` stages the overlay after the install now (see step 6 in the script) and aborts
early with these instructions if it finds the state. To recover — there is no user data yet,
Nextcloud never came up:

```bash
cd ~/projects/home-services/home-drive
docker compose down
sudo find /mnt/data/nextcloud/config -maxdepth 1 -name '*.php' -delete   # drop the pre-staged overlay
sudo rm -rf /mnt/data/nextcloud/db/pgdata                                # the installer may have half-written it
docker volume rm $(docker volume ls -q --filter name=nextcloud-html)
bash scripts/install.sh
```

Use `find -delete`, not `rm -f .../*.php`: that glob is expanded by *your own shell* before
`sudo` ever runs, and `config/` is mode `750` owned by the web user, so an ordinary user's
shell can't even list it to match the glob. Bash then passes the literal, unmatched string
`*.php` through, and `rm -f` reports no error and silently deletes nothing at all — the
overlay is still there afterward, and every symptom above just repeats.

A healthy first run says `Initializing nextcloud <version> …`, then `New nextcloud instance`,
and prints **no** `differs from the latest version` warnings at all.

### `occ status` throws a database connection error, forever, even though Postgres is fine

Symptom — `docker compose logs nextcloud-app` shows the automatic install failing with:

```
Doctrine\DBAL\Exception: Failed to connect to the database: An exception occurred in the
driver: SQLSTATE[08006] [7] connection to server at "127.0.0.1", port 5432 failed:
Connection refused
```

and every later `occ status` (even run by hand, minutes afterward, with `nextcloud-db`
reporting `Healthy` and staying up fine) throws the exact same error. `docker exec
homedrive-nextcloud-app env | grep -i postgres` shows `POSTGRES_HOST=nextcloud-db`, correct.

Postgres's very first start on a brand-new `pgdata` runs a throwaway `initdb` server before
the real one; that first server binds **only** the Unix socket, never TCP:

```
LOG:  listening on Unix socket "/var/run/postgresql/.s.PGSQL.5432"   ← throwaway server
LOG:  database system is shut down
LOG:  listening on IPv4 address "0.0.0.0", port 5432                ← the real one, moments later
```

`nextcloud-db`'s healthcheck (`pg_isready`, no `-h`) checks the Unix socket, which the
throwaway server also answers — so it can report `healthy` a moment before the real server
is the one actually listening on TCP. `nextcloud-app` starts right then, its one-shot
automatic install (env vars are only ever read during this one attempt, to write
`config.php`) hits `connection refused` on the network, and gives up. No later `docker exec
occ` call ever gets a different answer, because the install that would have written
`config.php` never happens again on its own — the entrypoint runs it exactly once, at
container start, not on every command.

`docker-compose.yml`'s `nextcloud-db` healthcheck now forces `pg_isready -h 127.0.0.1`,
specifically to fail during the throwaway-server window (TCP-only, never socket-only) so
this can't happen on a fresh install anymore. If you hit this anyway, `install.sh` detects
it directly (distinct from the message above — same section, different cause) and retries
by restarting `nextcloud-app` once the database has had time to settle, since the fix really
is just retrying the one-shot install after the real server is up.

**If restarting `nextcloud-app` doesn't help, check for a config.php that already exists**
— this is a second, different cause that produces the *identical* error message, and no
amount of restarting or waiting fixes it:

```bash
docker exec homedrive-nextcloud-app test -f /var/www/html/config/config.php && echo EXISTS
sudo cat /mnt/data/nextcloud/config/config.php | grep -E 'dbhost|dbname|dbuser|installed'
```

If `config.php` already exists and claims `'installed' => true`, Nextcloud never attempts a
fresh install at all — it goes straight to using whatever database settings are already in
that file. If `dbhost` there isn't `nextcloud-db`, the file is left over from a **different,
older Nextcloud install** entirely (a different `dbhost`/`dbname`/`dbuser`, possibly an old
Tailscale-hostname-based `trusted_domains` entry from before this stack existed in its
current form), not anything this stack's own `install.sh` ever wrote. `install.sh` detects
this distinctly too (a config.php already existing is not the startup race the automatic
retry above is for) and tells you directly rather than retrying uselessly. There is no user
data at this point on *this* stack — that stale file claiming `installed: true` is exactly
why Nextcloud never got the chance to create any of its own:

```bash
docker compose down
sudo find /mnt/data/nextcloud/config -maxdepth 1 -name '*.php' -delete
sudo rm -rf /mnt/data/nextcloud/db/pgdata
docker volume rm $(docker volume ls -q --filter name=nextcloud-html)
bash scripts/install.sh
```

(Same `find -delete`, not `rm -f .../*.php`, and for the same reason as the section above —
that glob is expanded by your own shell before `sudo` runs, and can't match anything in this
`750`, web-user-owned directory, so `rm -f` silently deletes nothing.)

### Tailscale profile: everything is healthy but nothing answers on port 443

Almost always a bad `serve.json`. `containerboot` expands **only** `${TS_CERT_DOMAIN}` in
that file. `${TS_HOSTNAME}`, `${TS_TAILNET}` and friends are passed through verbatim,
producing a serve config for a hostname that doesn't exist.

```bash
docker exec homedrive-tailscale tailscale serve status
docker exec homedrive-tailscale cat /config/tailscale/serve.json
```

The `serve status` output must show your real MagicDNS name, not a literal `${...}`.

### Image pull fails: `tls: bad record MAC`

A TLS record failed its integrity check, meaning bytes were corrupted between the registry
and the Pi. It is not a Docker or registry problem. On a Pi 5 the usual causes are, in order:

1. **NIC offload bugs**: payloads get mangled after checksums are computed, so Ethernet CRC
   and TCP checksums never catch it. Test with
   `sudo ethtool -K eth0 tso off gso off gro off tx off rx off`, and persist with
   `sudo nmcli connection modify "Wired connection 1" ethtool.feature-tso off ethtool.feature-gso off ethtool.feature-gro off ethtool.feature-tx off ethtool.feature-rx off`.
2. **Under-voltage**: `vcgencmd get_throttled` must print `0x0`. A Pi 5 with a bus-powered
   SSD needs a real 5V / 5A supply.
3. **USB 3 interference with 2.4 GHz Wi-Fi**: only relevant if you're on `wlan0`.

`install.sh` retries the pull three times, and if the registry is still unreachable but every
image is already on disk it continues with what it has rather than aborting. To skip the pull
entirely:

```bash
bash scripts/install.sh --skip-pull
```

### TUN device not found (Tailscale profile only)
```bash
ls -la /dev/net/tun     # should exist
sudo modprobe tun       # load the module
echo "tun" | sudo tee /etc/modules-load.d/tun.conf  # persist across reboots
```

### MagicDNS / HTTPS cert not working (Tailscale profile only)
- In the Tailscale admin console → DNS → enable MagicDNS.
- Machines → click your Pi → enable HTTPS.
- Inside the container: `docker exec homedrive-tailscale tailscale cert <hostname>.<tailnet>.ts.net`

### External drive not mounting
```bash
lsblk -f                   # find the UUID
cat /etc/fstab             # verify the entry
sudo mount -a              # try mounting all fstab entries
journalctl -xe | grep mount  # check errors
```

### Container stays unhealthy
```bash
docker compose ps
docker compose logs nextcloud-app
docker compose logs nextcloud-db
docker compose logs nextcloud-web
```

## Docs

- [Hardware guide](docs/HARDWARE.md)
- [OS + Docker setup](docs/SETUP.md)
- [Backups](docs/BACKUP.md)
- [Tailscale integration](../tailscale/README.md) (shared with PiHub)

## Scripts

| Script | What it does |
|--------|--------------|
| `scripts/mount-drive.sh` | One-time: format and persistently mount the data drive |
| `scripts/install.sh` | Bring the stack up. Idempotent, so re-run it after any config change |
| `scripts/autostart.sh` | Turn start-at-boot on or off, and check which it is |
| `scripts/backup.sh` | Nightly database + config backup |
| `scripts/restore.sh` | Restore from a backup archive |
