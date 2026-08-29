# The Drive — Nextcloud on the Pi

Google-Drive-style storage on your own hardware: browse and edit in a browser, sync clients
on desktop and mobile, users and sharing — and file locking, so two people cannot write the
same file at the same time.

It is an **optional add-on**. The core stack (FileBrowser + CouchDB + Tailscale) runs
without it, and a plain `docker compose up -d` does not start it.

---

## Why Nextcloud and not something lighter

| | Sync clients | Browse & edit in a browser | Locking | Files stay plain on disk |
|---|---|---|---|---|
| **Nextcloud** | ✅ desktop + mobile | ✅ | ✅ transactional **and** exclusive | ✅ |
| Seafile | ✅ | ✅ | partial | ❌ opaque block store |
| Syncthing | ✅ peer-to-peer | ❌ no central UI | ❌ creates conflict copies | ✅ |
| Plain WebDAV | ❌ mount only | limited | ✅ LOCK only | ✅ |

Syncthing is the interesting near-miss: it syncs beautifully, but when two devices change
one file it keeps both and names one `file.sync-conflict-2026….md`. That is the exact
failure this deployment is meant to prevent, so it was ruled out.

Deliberately **not** installed: Collabora / OnlyOffice. Simultaneous collaborative editing
is the opposite answer to the same question — and neither runs comfortably on a Pi.

---

## Install

Run `scripts/install.sh` first, then:

```bash
cd ~/home-services/home-drive

# 1. Add the Nextcloud block from .env.example to your .env and fill it in.
#    Generate the two machine passwords, do not invent them:
openssl rand -base64 32     # NEXTCLOUD_DB_PASSWORD
openssl rand -base64 32     # NEXTCLOUD_REDIS_PASSWORD

# 2. Install
bash scripts/install-drive.sh
```

First run downloads roughly 500 MB and then unpacks Nextcloud into a fresh volume; on a Pi
this takes several minutes, and the installer waits for it rather than failing.

Then open **`https://<TS_HOSTNAME>.<tailnet>.ts.net:9443/`** and sign in as
`NEXTCLOUD_ADMIN_USER`.

### Why a separate port

FileBrowser keeps `/` on 443, and the drive gets its own port. Running Nextcloud in a
subdirectory requires webroot rewriting plus special handling for `/.well-known`, and breaks
CalDAV/CardDAV discovery in ways that are tedious to debug. A port is one line in
`serve.json` and everything works normally.

Change it by editing `NEXTCLOUD_PORT` in `.env` **and** `config/tailscale/serve.json` —
that file is static JSON and cannot read `.env`. The installer refuses to run if the two
disagree, because the symptom otherwise is a drive that is up but unreachable with no error
anywhere.

---

## Clients

Install the official clients and point them at `https://<host>.<tailnet>.ts.net:9443`:

- **Desktop** (Windows/macOS/Linux) — full two-way sync of selected folders, or Virtual
  Files mode where nothing is downloaded until opened.
- **Android / iOS** — browse, auto-upload photos, make files available offline.
- **Anything WebDAV** — `https://<host>.<tailnet>.ts.net:9443/remote.php/dav/files/<user>/`
  works in Windows Explorer, macOS Finder, Nautilus, and rclone.

The device must be on your tailnet. That is the whole security boundary — there is no
public endpoint to attack.

**Use an app password per device**, not your login: Personal settings → Security → Devices &
sessions → Create new app password. A lost phone is then revoked with one click and cannot
be used to change your password or read your sessions.

---

## How the corruption protection actually works

Three separate mechanisms, and it is worth knowing which one does what — they fail
differently.

### 1. Transactional file locking — automatic

Every write takes a short-lived lock in Redis first. A second client trying to write the
same file gets `423 Locked` and retries, instead of interleaving its bytes with the first
writer's. **This is the thing that prevents corruption**, it is always on, and you never see
it unless two clients genuinely collide.

It needs shared, fast, atomic storage, which is why there is a Redis container:
`'filelocking.enabled' => true` with `memcache.locking` pointed at Redis in
[zz-homedrive.config.php](../config/nextcloud/zz-homedrive.config.php).

Locks expire after 15 minutes (`filelocking.ttl`) so a client that dies mid-write cannot
block a file forever. The `nextcloud-cron` container is what actually clears them — which is
why that container is not optional either.

### 2. Exclusive locks — deliberate, user-visible

The `files_lock` app, installed by `install-drive.sh`. Right-click a file → **Lock file**.
While locked:

- everyone else sees it as read-only, with your name and the time,
- the desktop clients refuse to upload changes to it,
- WebDAV clients (Word, Excel, LibreOffice over a mounted drive) take and release these
  locks *automatically* when they open and close a document.

This is the answer to "two people must not edit the same file at once" in the workflow
sense. Unlock manually, or let it expire — a lock a user forgot about does not become
permanent.

### 3. Versions and trash — the recovery net

Locking prevents the collision; versions save you when something goes wrong anyway.
Every change keeps a version (90 days) and deleted files sit in the trash (30 days), both
set to `auto` so Nextcloud shrinks them rather than filling the drive.

Right-click → Versions → Restore.

### What none of it protects against

- **Two people editing the same file on purpose, sequentially.** The second person's save
  wins, and the first version is in the version history. Locking is advisory in the sense
  that a user can always unlock.
- **A file edited outside Nextcloud.** See the next section.
- **Bit rot on the drive itself.** That is what SMART monitoring and backups are for.

---

## The one rule: nothing else writes into the drive

Nextcloud keeps an index of every file in its database. Write into
`${DATA_PATH}/nextcloud/data/` from outside — a shell, rsync, FileBrowser — and Nextcloud
does not know the file exists. Worse, it may overwrite it, because as far as it is
concerned that name is free.

So: **FileBrowser owns `${DATA_PATH}/files/`, the drive owns `${DATA_PATH}/nextcloud/data/`,
and they never share a directory.**

If you do have to add files from outside, tell Nextcloud afterwards:

```bash
docker exec -u www-data homedrive-nextcloud-app php occ files:scan --all
```

Want the FileBrowser tree visible inside the drive as well? Do it properly, through
**Settings → Administration → External storage** as a *Local* mount. Nextcloud then knows
it is external and rescans it — but locking and versioning do **not** apply there, so it is
a viewing convenience, not a place to collaborate.

---

## Operating it

### Starting and stopping

The drive's containers live behind the `drive` compose profile. `install-drive.sh` adds
`COMPOSE_PROFILES=drive` to `.env`, and from then on the ordinary commands cover
everything:

```bash
docker compose ps              # all eight containers
docker compose stop            # stop, keep them
docker compose down            # stop and remove
docker compose up -d           # bring the whole stack back
```

Without that line in `.env`, compose **silently ignores** the five drive containers —
`down` removes only the core stack and reports success, which looks exactly like the drive
having disappeared. If you hit that, either add the line or pass the profile explicitly:

```bash
docker compose --profile drive down
```

To take the drive down but leave the rest of the stack running:

```bash
docker compose stop nextcloud-web nextcloud-app nextcloud-cron nextcloud-redis nextcloud-db
```

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

Health monitoring already covers the drive — [health-monitor.sh](../scripts/health-monitor.sh)
picks up the five containers automatically when they exist, and
`bash scripts/health-dashboard.sh` shows a `drive` line with the version, plus the
Nextcloud share of the disk usage breakdown. For what actually moved on the drive:

```bash
homedrive-status --drive        # files added / changed / deleted, and the backup
homedrive-status --drive --scan # force a fresh walk instead of the cached one
```

That walks `data/<user>/files` from inside the container — the host cannot read it — and
skips versions and the trash, which would otherwise double-count every edit. It alerts on three states a *running* container
will not tell you about: install unfinished, stuck in maintenance mode, and a pending
database upgrade after an image pull.

### Upgrades

```bash
docker compose --profile drive pull
docker compose --profile drive up -d
docker exec -u www-data homedrive-nextcloud-app php occ upgrade   # if asked to
```

Never skip a major version — Nextcloud only supports one-major-at-a-time upgrades. Pin
`NEXTCLOUD_TAG` in `.env` once the stack works, and step it deliberately.

### Backups

`scripts/backup.sh` handles the drive automatically when it is running:

- puts Nextcloud in maintenance mode so the dump is coherent,
- `pg_dump`s the database and validates that the dump is not truncated,
- archives `config/` (which holds `config.php`, and therefore the instance id and the
  secret — a restore without it is not a restore),
- takes Nextcloud back out of maintenance mode, including on failure or Ctrl-C.

User files are **excluded by default**, exactly like the FileBrowser tree, because a
multi-terabyte tar every night is not a backup strategy. Set
`BACKUP_INCLUDE_NEXTCLOUD_DATA=true` to include them — the drive then stays offline for the
whole run — or mirror `${DATA_PATH}/nextcloud/data/` with rclone/rsync separately, which is
the better answer.

To restore: recreate the stack, `psql` the dump back in, unpack `config.tar`, restore the
data directory, then `occ maintenance:repair` and `occ files:scan --all`.

---

## Security notes specific to this setup

**Everything is bound to loopback inside the Tailscale namespace.** This deserves emphasis
because it is the one place this compose file differs from every Nextcloud example online.
All the containers run with `network_mode: service:tailscale`, so they share a network stack
that owns a tailnet IP. A service left on its default `0.0.0.0` here is not "internal" — it
is published to every device on your tailnet. Hence:

| Service | Bound to | Set in |
|---|---|---|
| PostgreSQL | `127.0.0.1:5432` | `command: postgres -c listen_addresses=127.0.0.1` |
| Redis | `127.0.0.1:6379` + password | `command: redis-server --bind 127.0.0.1 --requirepass` |
| php-fpm | `127.0.0.1:9000` | [`zz-listen.conf`](../config/nextcloud/zz-listen.conf) |
| nginx | `127.0.0.1:8081` | [`nginx.conf`](../config/nextcloud/nginx.conf) |

php-fpm is the one that really matters: FastCGI has no authentication whatsoever, and an
exposed port 9000 is remote code execution for anyone on the tailnet.

**Real client IPs.** `tailscale serve` terminates TLS and proxies from 127.0.0.1, so without
`trusted_proxies` every request would appear to come from localhost — and Nextcloud's
brute-force protection would rate-limit all users together after any one of them fumbled a
password. It is set, along with `OVERWRITEPROTOCOL=https`, without which Nextcloud emits
`http://` URLs and the desktop client fails with a redirect loop that looks like a login bug.

**Server-side encryption is deliberately off.** It stops deduplication working, makes
recovery from a damaged database considerably harder, and protects against a threat model
(untrusted storage backend) that does not apply to a disk in your house. Encrypt the drive
itself with LUKS if that is the concern.

**Turn on two-factor authentication** for the admin account: Apps → search "Two-Factor TOTP"
→ enable, then Personal settings → Security.

---

## Resource cost on a Pi 5

Roughly 900 MB of RAM for the five containers at idle, and the drive is comfortable on a
4 GB Pi 5 with an SSD. Two things to watch:

- **Previews** are the most expensive thing Nextcloud does. The config caps them at
  1024×1024 and trims the provider list to images and audio; the default list spawns
  external binaries for office documents and video.
- **The database on an SD card** will be the bottleneck and will wear the card out. If the
  OS is on microSD, this is the argument for the NVMe HAT in [HARDWARE.md](HARDWARE.md).

If the box feels slow, look at `bash scripts/health-dashboard.sh --watch` while using the
drive — CPU, disk throughput and per-container memory are all on one screen.
