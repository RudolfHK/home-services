# Monitoring — Health Check and Status Screen

Two scripts, deliberately separate, because "tell me if something breaks" and "show me how
the drive is doing" are different jobs with opposite requirements.

| | `health-monitor.sh` | `health-dashboard.sh` |
|---|---|---|
| Runs | Automatically, every 15 min | When you ask |
| Output | Silence, unless there is a problem | A status screen; sections chosen by flag |
| Costs | Cheap; safe to run unattended | ~1s for the base view; walks a file tree only when asked |
| Alerts | ntfy, with repeat suppression | Never |
| Exit code | 0 ok / 1 warn / 2 fail | Always 0 |
| Needs the repo | No — installed as `homedrive-health` | No — installed as `homedrive-status` |

Both read the same collection library (`scripts/lib/stats.sh`), so they can never disagree
about whether the drive is healthy.

---

## Install

```bash
cd ~/home-services/home-drive
bash scripts/install-monitoring.sh
```

That does five things:

1. creates `/var/lib/homedrive` for history, counters and the file manifest,
2. installs `homedrive-health.service` + `.timer` (every 15 minutes),
3. symlinks `homedrive-health` and `homedrive-status` into `/usr/local/bin`,
4. adds you to the `tty` group so the status can be drawn on the attached screen,
5. runs the first check, which seeds the file manifest.

No systemd (or you prefer cron):

```bash
bash scripts/install-monitoring.sh --cron     # hourly crontab entry + logrotate
```

Remove everything again:

```bash
bash scripts/install-monitoring.sh --uninstall
```

`/var/lib/homedrive` is left behind on uninstall — it holds your history and the manifest
that makes deletion detection work.

---

## Daily use

```bash
homedrive-status              # base view: storage, Pi, transfer, services
homedrive-status --drive      # + Nextcloud file activity, backup, issue list
homedrive-status --obsidian   # + the same for the FileBrowser / Obsidian tree
homedrive-status --all        # both
homedrive-status --watch      # live, refreshes every 5s, Ctrl-C to leave
homedrive-status --scan       # force a fresh file scan instead of the cached one
homedrive-status --compact    # one screenful of essentials
homedrive-status --json       # every metric, for scripting

homedrive-health --verbose    # run the unattended check by hand, showing every line
homedrive-health --status     # what the last scheduled run found, without re-checking
systemctl list-timers homedrive-health.timer
journalctl -u homedrive-health -n 50
```

From a checkout, the same scripts are `bash scripts/health-dashboard.sh` and
`bash scripts/health-monitor.sh`.

### Base view versus subsystem views

**Storage, the Pi, transfer and the services are always shown.** They describe the machine,
and it is the same machine whichever subsystem you came to look at.

**File activity, backup and the itemised issue list are per-subsystem**, behind `--drive`
and `--obsidian`. This is not only about screen space: walking a file tree's metadata is by
far the most expensive thing the dashboard does, and the flagless view skips both trees and
returns in about a second. Ask for a subsystem and only that tree is walked.

Nothing is hidden dangerously. When the issue list is off and something is wrong, the base
view still ends with a line like:

```
✖ 3 issue(s) outstanding — --drive or --obsidian to itemise them
```

and a failed container or an unmounted drive is already coloured red in the sections above.

The **monitor** ignores all of this and always scans both trees: noticing that fifty files
vanished is one of the things it exists for.

---

## What is measured

**Services** — every container's status, health, restart count, uptime, and (on the
dashboard) its CPU and memory. Then the things a container can be "running" while failing
to do: CouchDB answering `/_up`, the admin credentials still being accepted, FileBrowser
answering on `:8080`, and Tailscale's `BackendState` with the peer count.

**Storage** — usage of the data drive and the OS drive with free space, filesystem and
device; inode usage, which fills before bytes do on a vault of many small notes; a
breakdown of where the space went (`files/`, `couchdb/`, `filebrowser/`, `backups/`); and
SMART health, drive temperature, power-on hours and reallocated sectors where `smartctl`
is installed.

The check that matters most is whether `DATA_PATH` is a *mount point*. If the external
drive drops off the USB bus, the path still exists as an empty directory on the OS drive,
and nothing else on the box will tell you.

**Raspberry Pi** — SoC temperature, CPU utilisation, load average against core count,
memory and swap, fan RPM, uptime, and the throttling flags from `vcgencmd get_throttled`.
Those flags are what explain a Pi that is mysteriously slow or keeps dropping USB drives:
under-voltage *now* is a critical alert, under-voltage *since boot* is a warning.

**Transfer** — download and upload rates per interface, plus disk read/write throughput.
The dashboard samples for one second, so it shows what is happening right now; the monitor
diffs its counters against the previous run, so its figures are averages over the interval
and are what the sparklines are built from.

**File activity** — total file count and size, the most recently written files, and what
was **added, modified and deleted** since the last check. Deletions are the reason this
keeps a manifest: `find` can list what exists, never what stopped existing. A mass deletion
raises a warning while the deleted files are still inside the backup retention window.

Two trees are tracked independently, with the same logic and separate state:

| Flag | Tree | Walked |
|------|------|--------|
| `--obsidian` | `$DATA_PATH/files` — FileBrowser and anything you put there | on the host |
| `--drive` | Nextcloud's `data/<user>/files` | inside the container |

The drive's tree cannot be walked from the host at all: it is mode 750 owned by the web
user, so the account running the health check would get nothing but permission errors.
Only `data/<user>/files` is counted — `files_versions`, `files_trashbin` and `appdata_*`
live under the same root, and including them would report every single edit twice (once as
the file, once as the version it just created) and every deletion as an addition in the
trash.

**Sync** — CouchDB document count, database size, and the change in `update_seq` since the
last check. That last number is the honest answer to "is anything actually syncing?" — the
document count barely moves when you edit a note, but the update sequence always does.
`scripts/obsidian-check.sh` remains the tool for debugging one specific device.

**Backups** — newest archive, its age and size, how many are kept and their total size.
Warns at 26 hours and fails at 48, which is what catches a nightly job that quietly stopped.

---

## The screen on the Pi

If a display is connected, the result is drawn on the console after every scheduled check
and stays up for five seconds.

Detection is real, not assumed: a DRM connector must report `connected`, or `/dev/fb0` must
exist (for SPI/DSI LCD HATs). A headless Pi still has a `/dev/tty1`, so its existence proves
nothing and is never used as the test.

```bash
homedrive-status --screen                 # draw it now, for 5s
homedrive-status --screen --duration 30   # ...for 30s
homedrive-status --force-screen           # draw even if no display is detected
```

Tune it in `.env`:

```bash
HEALTH_DISPLAY=auto             # auto | off | force
HEALTH_DISPLAY_SECONDS=5
HEALTH_DISPLAY_TTY=/dev/tty1
HEALTH_DISPLAY_FONT=Uni2-Terminus32x16   # big enough to read across a room
```

Install the font pack first if you set `HEALTH_DISPLAY_FONT`:

```bash
sudo apt-get install -y console-setup fonts-terminus
ls /usr/share/consolefonts/
```

The layout drops to a compact one screenful of essentials automatically when the console is
smaller than 70×22, so a small LCD HAT gets something readable rather than a truncated
full-size dashboard.

### A permanent display

For a Pi with a screen that should always show the dashboard:

```bash
bash scripts/install-monitoring.sh --screen
sudo systemctl disable --now getty@tty1     # or the login prompt fights it for tty1
sudo systemctl enable --now homedrive-screen
```

It redraws every 10 seconds. Stopping the service gives the console back.

---

## Alerts

Set `NTFY_URL` in `.env` and problems arrive as push notifications.

Repeat suppression matters more than it looks. An hourly check against a drive that has
been full since Tuesday would send 168 identical notifications a week — and you would mute
the topic, right before the one alert that mattered. So a given problem notifies once, then
not again for `HEALTH_ALERT_REPEAT_HOURS` (default 6) unless what is wrong changes. A single
"recovered" message is sent when everything passes again.

CPU, memory and load spikes are coloured on the dashboard but do **not** alert: a file
server under load is doing its job. Set `HEALTH_ALERT_ON_RESOURCE=true` if you want them to.

Without `NTFY_URL` the exit status still does the work — cron mails you on any non-zero
exit, and `systemctl status homedrive-health` shows the last result.

---

## Cost of the file scan

The activity scan walks the metadata of every file under `$DATA_PATH/files`. On an SSD with
a few hundred thousand files that is a second or two; it is nonetheless:

- **cached** — reused for `HEALTH_SCAN_INTERVAL_MIN` (default 30) minutes, so a dashboard
  refresh never triggers a new walk. The dashboard marks reused figures `[cached]`; `--scan`
  forces a fresh one.
- **time-boxed** — abandoned after `HEALTH_SCAN_TIMEOUT` (default 90 s), reporting partial
  figures and a warning rather than hanging the check.
- **bounded** — above `HEALTH_SCAN_MAX_FILES` (default 200 000) the added/deleted/modified
  diff is skipped, because it holds one entry per file in memory. Counts and sizes are still
  reported.

The scheduled check also runs at `Nice=10` with idle I/O priority, so it yields to anything
actually serving files.

---

## Files it writes

Everything lives in `/var/lib/homedrive` (override with `HEALTH_STATE_DIR`):

| File | What it is |
|------|-----------|
| `counters.env` | Last run's network/disk/CPU counters — the basis of every rate |
| `history.csv` | Rolling samples for the sparklines (capped at 240 points) |
| `live.csv` | Same, for `--watch` sessions, kept separate so 5-second samples do not pollute the long-term history |
| `files-manifest.tsv` `drive-manifest.tsv` | Path, mtime and size of every file at the last scan, one per tree |
| `files-added.txt` `files-deleted.txt` `files-modified.txt` | The last diff of the FileBrowser tree |
| `drive-added.txt` `drive-deleted.txt` `drive-modified.txt` | The same for the Nextcloud tree |
| `files-recent.tsv` `drive-recent.tsv` | Most recently written files |
| `status.json` | Full metric set from the last unattended run |
| `status.txt` | One-line summary (`homedrive-health --status` prints this) |
| `alert.env` | Which alert was last sent, and when |

It is deliberately **not** on the data drive: the state has to survive the drive going
missing, since that is exactly when you need the history.

---

## `healthcheck.sh`

Still there, and still works — it forwards to `health-monitor.sh --verbose` so an existing
crontab entry keeps running. New installs should use `install-monitoring.sh`.
