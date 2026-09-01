# Home Services: Complete Raspberry Pi 5 Setup

This repo holds three independent, self-hosted stacks for a Raspberry Pi 5:

- **`home-drive/`**: a private file server (FileBrowser + CouchDB/Obsidian
  sync), with an optional Nextcloud add-on for Google-Drive-style storage,
  sync clients, and file management.
- **`pihub/`**: a unified dashboard bringing PiTune (local music + YouTube
  audio), Jellyfin (video/TV), and a health-monitoring homepage together
  behind one URL.
- **`tailscale/`**: the shared access-control policy that lets any of the
  above be reached securely from outside the house.

Each has its own README with full detail; this page is the single path
through all of them for one specific, complete setup: everything on one Pi,
reachable remotely over Tailscale, with all of PiHub's music/video library
living *inside* home-drive's Nextcloud, so adding, moving, or deleting a
file through Nextcloud is what manages the library. No separate folder to
keep in sync by hand.

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
timedatectl              # "System clock synchronized: yes" — needed for HTTPS certs later
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

```bash
# Load the TUN module — every tailscale container in this repo needs it
ls -la /dev/net/tun || sudo modprobe tun
echo "tun" | sudo tee /etc/modules-load.d/tun.conf
```

**Mount the external SSD at `/mnt/data`.** Everything in this guide,
home-drive's own data, Nextcloud's files, and PiHub's non-library folders,
lives under this one path, so both stacks are pointed at the same drive.

```bash
git clone https://github.com/<you>/home-services.git ~/home-services
cd ~/home-services/home-drive
lsblk -f                          # identify the drive, e.g. /dev/sda1
sudo bash scripts/mount-drive.sh  # formats (if needed) + mounts at /mnt/data + adds fstab entry
mountpoint /mnt/data               # confirm it's really a separate mount, not a folder on the OS drive
```

If you'd rather mount it by hand or it's already mounted elsewhere, see
[`home-drive/README.md`](home-drive/README.md#4-attach-and-mount-the-data-drive)
for the manual steps; just make sure `DATA_PATH` in home-drive's `.env`
(step 3 below) matches wherever it lands.

---

## 2. Set up Tailscale (one-time tailnet policy)

Do this **before** starting any of the stacks below. It's what keeps a
freshly-joined Pi from exposing more than intended the moment it comes up,
and it's a single tailnet-wide setting, not something you repeat per stack.

1. Create a Tailscale account at https://login.tailscale.com if you don't
   have one.
2. Follow [`tailscale/docs/DEVICE-ONBOARDING.md`](tailscale/docs/DEVICE-ONBOARDING.md)'s
   **"One-time tailnet setup"** section: turn on device approval, and
   apply [`tailscale/acl-policy.hujson`](tailscale/acl-policy.hujson) in
   the admin console (that doc has the full click-by-click walkthrough,
   including what to do if this tailnet already has other rules on it).
   Substitute your own Tailscale login for every `REPLACE-ME` placeholder.
3. Keep that doc open. You'll come back to it in steps 3 and 4 to approve
   and tag each Pi, and later to approve your own phone/laptop.

---

## 3. Set up home-drive, with the Nextcloud add-on

home-drive is the file server whose Nextcloud install will hold PiHub's
media library. Full detail in [`home-drive/README.md`](home-drive/README.md);
condensed path for this setup:

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
| `TS_HOSTNAME` | e.g. `homepi` |
| `TS_TAILNET` | your tailnet name, e.g. `tail1234.ts.net` |
| `TS_EXTRA_ARGS` | `--advertise-tags=tag:home-drive-server` (required by the ACL from step 2) |
| `COUCHDB_PASSWORD` / `FILEBROWSER_ADMIN_PASSWORD` | strong passwords; `install.sh` rejects the placeholders |
| `PUID` / `PGID` | output of `id -u` / `id -g` |

Then bring up the base stack:

```bash
bash scripts/install.sh
```

Open the [Tailscale admin console](https://login.tailscale.com/admin/machines),
approve this Pi, and confirm it shows `tag:home-drive-server` (apply the
tag from the console's device list if `TS_EXTRA_ARGS` above didn't already
set it). See [`home-drive/docs/TAILSCALE.md`](home-drive/docs/TAILSCALE.md)'s
**"2b. Apply the shared ACL and advertise this node's tag"** if anything
here doesn't match.

### Install the Nextcloud add-on

This is the part that will actually hold PiHub's media, so it's required
for this setup even though home-drive treats it as optional:

```bash
cd ~/home-services/home-drive
# Generate these two, don't invent them:
openssl rand -base64 32     # → NEXTCLOUD_DB_PASSWORD
openssl rand -base64 32     # → NEXTCLOUD_REDIS_PASSWORD
nano .env   # add the Nextcloud block from .env.example, fill in both passwords above
bash scripts/install-drive.sh
```

First run downloads roughly 500 MB and takes several minutes on a Pi.
Once it's done, open `https://<TS_HOSTNAME>.<tailnet>.ts.net:9443/` and
sign in as `NEXTCLOUD_ADMIN_USER` (`admin` unless you changed it in
`.env`). See [`home-drive/docs/DRIVE.md`](home-drive/docs/DRIVE.md) for
everything about running it day to day.

### Create the Media folder

Still signed in to Nextcloud's web UI as `admin`:

1. Create a folder named **`Media`**.
2. Inside it, create four subfolders, named exactly (lowercase):
   **`music`**, **`videos`**, **`movies`**, **`shows`**.
3. Upload or sync your existing library into the matching subfolders (a
   desktop sync client is the easiest way to move a large existing
   collection in; see [`home-drive/docs/DRIVE.md`](home-drive/docs/DRIVE.md#clients)).

Creating these through Nextcloud itself, rather than by hand on the host,
means Nextcloud's own index already knows about them from the start. On
disk (confirm this matches what PiHub will read in step 4), this is:

```
/mnt/data/nextcloud/data/admin/files/Media/
├── music/
├── videos/
├── movies/
└── shows/
```

---

## 4. Set up PiHub, pointed at that Nextcloud folder

PiHub is what actually serves that library: Navidrome for music, Jellyfin
for video, plus the health-monitoring dashboard, all as one stack. Full
detail in [`pihub/README.md`](pihub/README.md); condensed path:

```bash
cd ~/home-services/pihub
bash scripts/setup.sh
```

When it asks for a **media storage path**, give it a plain folder that is
**not** inside Nextcloud, e.g. `/mnt/data/pihub`, creating it first if it
doesn't exist (`sudo mkdir -p /mnt/data/pihub`). This becomes `MEDIA_ROOT`,
used only for `downloads/`, `photos/`, and `backups/` once step 4b below
redirects the actual library elsewhere; the setup wizard's own
`music/videos/movies/shows` subfolders under it end up unused, which is
harmless.

Let `setup.sh` finish (it pulls images and starts core + homepage + PiTune
+ Jellyfin), then stop the two containers whose media mounts the next step
changes:

```bash
docker compose stop navidrome jellyfin
```

### 4b. Point the library at Nextcloud's Media folder

```bash
nano .env
```

Set:

```bash
MEDIA_GID=<see below>
MEDIA_LIBRARY_ROOT=/mnt/data/nextcloud/data/admin/files/Media
```

Find the right `MEDIA_GID`:

```bash
stat -c '%g' /mnt/data/nextcloud/data
```

home-drive's `install-drive.sh` deliberately locks that directory down to
Nextcloud's own internal user (mode `750`, not world-readable) so nothing
outside the Nextcloud container can read it by default. `MEDIA_GID` grants
Navidrome and Jellyfin read access through a supplementary group, without
touching that directory's ownership or loosening its permissions, and
without ever granting write access. See
[`pihub/README.md`](pihub/README.md#mounting-a-nextcloud-folder-as-your-media-library-optional)
for the full reasoning, including why `downloads/`, `photos/`, and
`backups/` deliberately stay out of Nextcloud's tree regardless.

Also add PiHub's own Tailscale tag, so the ACL from step 2 grants it
anything:

```bash
TS_EXTRA_ARGS=--advertise-tags=tag:pihub-server
```

Now bring everything back up:

```bash
docker compose up -d
```

### 4c. One-time manual steps

1. Open `http://<pi-ip>:4533/` and create your first Navidrome user.
   PiTune's own Library tab logs in with that account.
2. Open `http://<pi-ip>:8096/`, run Jellyfin's setup wizard, and add three
   libraries pointing at the container paths `/media/videos`,
   `/media/movies`, `/media/shows` (these already resolve to the Nextcloud
   folders from step 4b). Then go to **Dashboard → Networking → Base
   URL**, set it to `/jellyfin`, and restart: `./pihub restart jellyfin`.
3. Open `http://<pi-ip>/` (PiHub's dashboard) and confirm PiTune,
   Jellyfin, and the system stats all show healthy.

### 4d. Enable remote access for PiHub too (optional)

If you want PiHub reachable the same way as home-drive, from outside the
LAN over Tailscale:

```bash
pihub start tailscale
```

See [`pihub/README.md`](pihub/README.md#remote-access-via-tailscale-optional)
for the `API_TOKEN` prerequisite this profile enforces before it will
start.

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

**home-drive (FileBrowser + CouchDB, always running):**
```bash
cd ~/home-services/home-drive
docker compose stop     # turn off, survives reboots as "off"
docker compose up -d    # turn back on
```

**The Nextcloud add-on specifically** has its own systemd unit, because a
plain restart policy can't wait for the external drive to actually be
mounted before the containers start (see
[`home-drive/docs/DRIVE.md`](home-drive/docs/DRIVE.md#autostart-at-boot)
for why that distinction matters):
```bash
bash scripts/drive-autostart.sh status   # is it enabled? is it running?
bash scripts/drive-autostart.sh on
bash scripts/drive-autostart.sh off
```

**PiHub (dashboard, PiTune, Jellyfin):**
```bash
cd ~/home-services/pihub
./pihub stop all    # turn everything off, survives reboots as "off"
./pihub start all   # turn everything back on
# or target one piece: ./pihub stop jellyfin / ./pihub start pitune / etc.
```

A Pi reboot with everything left running should come back exactly as it
was: home-drive, Nextcloud, and PiHub all up, PiHub's library still
reading from Nextcloud's `Media` folder, both reachable on the LAN and,
if you enabled it, over Tailscale.

---

## Where to go next

| Question | See |
|---|---|
| Something in home-drive/Nextcloud isn't working | [`home-drive/README.md`](home-drive/README.md#troubleshooting), [`home-drive/docs/DRIVE.md`](home-drive/docs/DRIVE.md) |
| Something in PiHub/PiTune/Jellyfin isn't working | [`pihub/README.md`](pihub/README.md#troubleshooting) |
| A device can't reach something over Tailscale | [`tailscale/docs/DEVICE-ONBOARDING.md`](tailscale/docs/DEVICE-ONBOARDING.md)'s "Verifying it actually took effect" |
| Backups | [`home-drive/docs/BACKUP.md`](home-drive/docs/BACKUP.md) (home-drive's own data + Nextcloud); PiHub's `scripts/backup.sh` backs up its configs, not the media itself, since that already lives safely inside Nextcloud's own backed-up data |
| Health monitoring | [`home-drive/docs/MONITORING.md`](home-drive/docs/MONITORING.md) (home-drive's own health check and status screen); PiHub's dashboard at `http://<pi-ip>/` for PiHub's own services |
| Running PiTune standalone instead of through PiHub | [`pitune/README.md`](pitune/README.md), including its own [Nextcloud-mount section](pitune/README.md#mounting-a-nextcloud-folder-as-your-music-library-optional) if you go that route instead of PiHub's |
