# Home Services: Complete Raspberry Pi 5 Setup

This repo holds two independent, self-hosted stacks for a Raspberry Pi 5:

- **`home-drive/`**: Nextcloud, Google-Drive-style storage with sync clients,
  sharing, versioning, and file locking. Reachable directly on the LAN by
  default, with an optional Tailscale profile to reach it from outside too.
- **`pihub/`**: all media streaming behind one URL, music (Navidrome, plus
  YouTube search/streaming and auto-download into your library), movies and
  shows (Jellyfin), pictures (a Jellyfin Photos library), and PiMonitor
  (Pi/drive stats, file activity, who's playing what). Same networking
  model as home-drive: LAN-direct by default, Tailscale optional.
- **`tailscale/`**: the shared access-control policy used by both stacks'
  optional Tailscale profiles, so a device you approve once can reach
  either from outside the house.

Each has its own README with full detail; this page is the single path
through both for one specific, complete setup: everything on one Pi (OS and
this repo on their own NVMe SSD, all media data on a separately mounted
SSD), with PiHub's whole media library living *inside* home-drive's
Nextcloud, so adding, moving, or deleting a file through Nextcloud (web UI,
desktop sync, or phone app, from any device) is what manages the library.
No separate folder to keep in sync by hand.

Follow the sections in order. Each one links to the project's own docs for
depth; this page only carries the commands and values specific to this
combined setup.

---

## 1. Prepare the Pi

One-time OS and storage prep, shared by everything below. For the full
walkthrough (flashing the OS, hardening SSH, and more), see
[`home-drive/docs/SETUP.md`](home-drive/docs/SETUP.md); the condensed path:

```bash
# Confirm the base OS
uname -m                # must print: aarch64
timedatectl              # "System clock synchronized: yes"
sudo apt-get update && sudo apt-get full-upgrade -y
sudo reboot
```

```bash
# Install Docker + the Compose v2 plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
newgrp docker
docker compose version   # must print v2.x
```

**Two separate drives, on purpose.** The OS and this repo live on their own
boot drive, an NVMe SSD if your Pi 5 has the PCIe HAT for one (see
[`home-drive/docs/HARDWARE.md`](home-drive/docs/HARDWARE.md)); all the
actual data, Nextcloud's files and PiHub's media, lives on a **separate**
external SSD, mounted at `/mnt/data`. Keeping them apart means a botched OS
upgrade or a re-image never touches your data, and the data drive can be
unplugged and read from another machine directly if it ever needs to be.

```bash
git clone https://github.com/<you>/home-services.git ~/home-services
cd ~/home-services/home-drive
lsblk -f                          # identify the data drive, e.g. /dev/sda1
sudo bash scripts/mount-drive.sh  # formats (if needed) + mounts at /mnt/data + adds fstab entry
mountpoint /mnt/data               # confirm it's really a separate mount, not a folder on the OS drive
```

If you'd rather mount it by hand or it's already mounted elsewhere, see
[`home-drive/README.md`](home-drive/README.md#3-attach-and-mount-the-data-drive)
for the manual steps; just make sure `DATA_PATH` in home-drive's `.env`
(step 2 below) matches wherever it lands.

---

## 2. Set up home-drive (Nextcloud)

home-drive is the file server whose Nextcloud install will hold PiHub's
media library. It's usable entirely over the LAN with nothing beyond this
section; remote access is a separate, optional step 4. Full detail in
[`home-drive/README.md`](home-drive/README.md); condensed path:

```bash
cd ~/home-services/home-drive
cp .env.example .env
chmod 600 .env
nano .env
```

In `.env`, set at minimum:

| Variable | Value for this setup |
|---|---|
| `DATA_PATH` | `/mnt/data` (from step 1) |
| `NEXTCLOUD_LAN_HOSTNAME` | how you'll reach it on the LAN, e.g. `homepi.local` or a static IP |
| `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` | the first admin account |
| `NEXTCLOUD_DB_PASSWORD` / `NEXTCLOUD_REDIS_PASSWORD` | strong, random passwords: `openssl rand -base64 32` each; `install.sh` rejects the placeholder value |
| `PUID` / `PGID` | output of `id -u` / `id -g` |
| `TZ` | e.g. `Europe/London` |

Leave every `TS_*` variable empty for now; that's step 4.

```bash
bash scripts/install.sh
```

First run downloads roughly 500 MB and takes several minutes on a Pi.
Once it's done, open `http://<NEXTCLOUD_LAN_HOSTNAME>:<NEXTCLOUD_PORT>/`
(port defaults to `80`) and sign in as `NEXTCLOUD_ADMIN_USER`. See
[`home-drive/README.md`](home-drive/README.md) for everything about
running it day to day.

### Create the media folder

Still signed in to Nextcloud's web UI as `NEXTCLOUD_ADMIN_USER`:

1. Create a folder named **`media`**.
2. Inside it, create four subfolders, named exactly (lowercase):
   **`music`**, **`videos`**, **`shows`**, **`photos`**. **Not `movies`**:
   individual movie files routinely exceed 50GB, which causes real
   problems specific to Nextcloud (chunked-upload size limits, wasted
   preview-generation attempts, a much slower `files:scan`/backup pass).
   Movies get their own plain folder on the drive in step 3 instead,
   managed directly (copy/move/delete by hand), never through Nextcloud.
3. Upload or sync your existing library into the matching subfolders (a
   desktop sync client is the easiest way to move a large existing
   collection in; see [`home-drive/README.md`](home-drive/README.md#clients)).

Creating these through Nextcloud itself, rather than by hand on the host,
means Nextcloud's own index already knows about them from the start. On
disk (confirm this matches what PiHub will read in step 3), this is:

```
/mnt/data/nextcloud/data/<NEXTCLOUD_ADMIN_USER>/files/media/
├── music/
├── videos/
├── shows/
└── photos/
```

You don't need to create `music/YouTube/` yourself; PiHub creates that one
the first time it needs it (step 3 explains why it's separate).

---

## 3. Set up PiHub, pointed at that Nextcloud folder

PiHub is what actually serves that library: Navidrome for music (plus
YouTube search, streaming, and auto-download), Jellyfin for video and
photos, and the homepage dashboard with PiMonitor, all as one stack. It's
also usable entirely over the LAN with nothing beyond this section; remote
access is step 4. Full detail in [`pihub/README.md`](pihub/README.md);
condensed path:

```bash
cd ~/home-services/pihub
bash scripts/setup.sh
```

When it asks for a **media storage path**, give it a plain folder that is
**not** inside Nextcloud, e.g. `/mnt/data/pihub`, creating it first if it
doesn't exist (`sudo mkdir -p /mnt/data/pihub`). This becomes `MEDIA_ROOT`.
Once step 3b below redirects `music/videos/shows/photos` elsewhere, the
setup wizard's own subfolders of those four names under it end up unused,
which is harmless; `downloads/`, `backups/`, and, deliberately, `movies/`
keep using this path regardless (see step 3b for why movies stays out of
Nextcloud). Put your movie files straight into `MEDIA_ROOT/movies/` by
hand, copy/move/delete directly on the drive whenever your collection
changes.

Let `setup.sh` finish (it pulls images and starts core + homepage + PiTune
+ Jellyfin), then stop the two containers whose media mounts the next step
changes:

```bash
docker compose stop navidrome jellyfin
```

### 3b. Point the library at Nextcloud's media folder

```bash
nano .env
```

Set:

```bash
MEDIA_GID=<see below>
MEDIA_LIBRARY_ROOT=/mnt/data/nextcloud/data/<NEXTCLOUD_ADMIN_USER>/files/media
```

Find the right `MEDIA_GID`:

```bash
stat -c '%g' /mnt/data/nextcloud/data
```

home-drive's `install.sh` deliberately locks that directory down to
Nextcloud's own internal user (mode `750`, not world-readable) so nothing
outside the Nextcloud container can read it by default. `MEDIA_GID` grants
Navidrome and Jellyfin read access through a supplementary group, without
touching that directory's ownership or loosening its permissions, and
without ever granting write access. See
[`pihub/README.md`](pihub/README.md#mounting-a-nextcloud-folder-as-your-media-library-optional)
for the full reasoning, including why `downloads/`, `backups/`, and
`movies/` (individual files routinely exceed 50GB, a real problem
specific to Nextcloud) deliberately stay out of Nextcloud's tree
regardless, and how `music/YouTube/` differs from the rest.

Now bring everything back up:

```bash
docker compose up -d
```

### 3c. One-time manual steps

1. Open `http://<pi-ip>:4533/` and create your first Navidrome user.
   PiTune's own Library tab logs in with that account.
2. Open `http://<pi-ip>:8096/`, run Jellyfin's setup wizard, and add four
   libraries pointing at the container paths `/media/videos`,
   `/media/movies`, `/media/shows` (Movies/Shows/general video types) and
   `/media/photos` (Photos type); these already resolve to the Nextcloud
   folders from step 3b. Then go to **Dashboard → Networking → Base URL**,
   set it to `/jellyfin`, and restart: `./pihub restart jellyfin`.
3. Open `http://<pi-ip>/` (PiHub's dashboard) and confirm PiTune, Jellyfin,
   and the system stats all show healthy. The **PiMonitor** button in the
   sidebar shows the mounted drive's usage by default; its advanced tier
   (file activity, who's playing what) needs `API_TOKEN` (already set by
   `setup.sh`) and, optionally, `JELLYFIN_API_KEY` and
   `NAVIDROME_MONITOR_USER`/`NAVIDROME_MONITOR_PASSWORD` in `.env`; see
   [`pihub/homepage/README.md`](pihub/homepage/README.md#pimonitor).

YouTube tracks played in the Music tab are saved into `music/YouTube/`
automatically once played to completion (`DOWNLOAD_ENABLED=true` by
default). Since that lands inside Nextcloud's own data directory here,
Nextcloud's index doesn't learn about the new file on its own; run

```bash
docker exec -u www-data homedrive-nextcloud-app php occ files:scan --all
```

occasionally (by hand, or on a cron schedule) if you want saved tracks to
also show up when browsing `media/music/YouTube` from Nextcloud itself.
Set `DOWNLOAD_ENABLED=false` in PiHub's `.env` to turn the feature off
entirely instead.

---

## 4. Enable remote access over Tailscale (optional)

Both stacks work fully over the LAN with nothing above. Do this section
only if you also want either reachable from outside the house, from a
device you've explicitly approved.

1. Create a Tailscale account at https://login.tailscale.com if you don't
   have one.
2. Follow [`tailscale/docs/DEVICE-ONBOARDING.md`](tailscale/docs/DEVICE-ONBOARDING.md)'s
   **"One-time tailnet setup"** section: turn on device approval, and
   apply [`tailscale/acl-policy.hujson`](tailscale/acl-policy.hujson) in
   the admin console (that doc has the full click-by-click walkthrough,
   including what to do if this tailnet already has other rules on it).
   Substitute your own Tailscale login for every `REPLACE-ME` placeholder.
3. Per stack you want reachable this way, fill in its `TS_AUTHKEY`,
   `TS_HOSTNAME`, `TS_TAILNET`, and `TS_EXTRA_ARGS` (the tag it advertises:
   `tag:home-drive-server` or `tag:pihub-server`), then start its profile:
   ```bash
   cd ~/home-services/home-drive && docker compose --profile tailscale up -d
   cd ~/home-services/pihub && pihub start tailscale
   ```
   See [`home-drive/README.md`](home-drive/README.md#enabling-remote-access-over-tailscale-optional)
   and [`pihub/README.md`](pihub/README.md#remote-access-via-tailscale-optional)
   for each stack's own prerequisites (PiHub's Tailscale profile in
   particular refuses to start without `API_TOKEN` set).
4. Follow [`tailscale/docs/DEVICE-ONBOARDING.md`](tailscale/docs/DEVICE-ONBOARDING.md)'s
   **"Adding a new personal device"** section for your phone/laptop.

---

## 5. Enable or disable everything at boot

Every container in this repo uses Docker's own `restart: unless-stopped`
policy: it comes back after a reboot if it was running when the Pi went
down, and stays off if you'd explicitly stopped it. That policy only takes
effect if Docker itself starts on boot, which the installer in step 1
already enabled. Confirm it:

```bash
systemctl is-enabled docker   # should print "enabled"
sudo systemctl enable --now docker   # if it doesn't
```

With that confirmed, each piece toggles independently:

**home-drive (Nextcloud)** has its own systemd unit, because a plain
restart policy can't wait for the external drive to actually be mounted
before the containers start (see
[`home-drive/README.md`](home-drive/README.md#autostart-at-boot) for why
that distinction matters):
```bash
cd ~/home-services/home-drive
bash scripts/autostart.sh status   # is it enabled? is it running?
bash scripts/autostart.sh on
bash scripts/autostart.sh off
```

**PiHub (dashboard, PiTune, Jellyfin):**
```bash
cd ~/home-services/pihub
./pihub stop all    # turn everything off, survives reboots as "off"
./pihub start all   # turn everything back on
# or target one piece: ./pihub stop jellyfin / ./pihub start pitune / etc.
```

A Pi reboot with everything left running should come back exactly as it
was: home-drive/Nextcloud and PiHub both up, PiHub's library still reading
from Nextcloud's `media` folder, both reachable on the LAN and, if you
enabled it, over Tailscale.

---

## Where to go next

| Question | See |
|---|---|
| Something in home-drive/Nextcloud isn't working | [`home-drive/README.md`](home-drive/README.md#troubleshooting) |
| Something in PiHub/PiTune/Jellyfin/PiMonitor isn't working | [`pihub/README.md`](pihub/README.md#troubleshooting) |
| A device can't reach something over Tailscale | [`tailscale/docs/DEVICE-ONBOARDING.md`](tailscale/docs/DEVICE-ONBOARDING.md)'s "Verifying it actually took effect" |
| Backups | [`home-drive/docs/BACKUP.md`](home-drive/docs/BACKUP.md) (home-drive's own database + config, and Nextcloud's user files if you opt in); PiHub's `scripts/backup.sh` backs up its own configs, not the media itself, since that already lives safely inside Nextcloud's own backed-up data |
| Pi/drive/file/user-activity monitoring | PiHub's dashboard at `http://<pi-ip>/`, PiMonitor button, described in [`pihub/homepage/README.md`](pihub/homepage/README.md#pimonitor) |
| Browsing music by mood/similarity instead of artist/album | Not implemented yet; see [`pihub/README.md`](pihub/README.md#discover-not-yet-implemented) |
