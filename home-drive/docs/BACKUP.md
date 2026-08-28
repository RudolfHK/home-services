# Backup Guide

---

## What Gets Backed Up

| Data | Location on Pi | In the archive? |
|------|---------------|------------------|
| CouchDB Obsidian vault | `$DATA_PATH/couchdb/` | **Yes** — dumped as JSON per database, with attachments inlined as base64 |
| FileBrowser config / users | `$DATA_PATH/filebrowser/filebrowser.db` | **Yes** — consistent SQLite hot copy via `.backup` |
| Stack config files | `config/` in the project dir | **Yes** |
| FileBrowser files | `$DATA_PATH/files/` | **Opt-in** — set `BACKUP_INCLUDE_FILES=true` |
| `.env` (secrets) | project dir | **No** — see below |

`.env` is deliberately excluded: it holds the tailnet auth key and both admin passwords,
and the archive may be pushed to third-party storage by rclone. Store it separately — a
password manager or an encrypted file.

Archives are written with mode `0600` and `$DATA_PATH/backups` with mode `0700`: the
archive contains every note in your vault in plaintext JSON.

### Why the file tree is opt-in

Copying `$DATA_PATH/files/` into the nightly archive turns a 30-second job into one that
can run for hours and needs as much free space again on the same drive — and it is a
*second* copy on the *same* disk, which is not a backup in any meaningful sense. Use
`rclone sync` or a plain `rsync` job to a different device for the file tree, and let
`backup.sh` handle the two things that cannot be copied safely with `cp`: the live CouchDB
databases and the live SQLite file.

### Staging location

The dump is staged in `$DATA_PATH/tmp/`, not `/tmp`. On Raspberry Pi OS `/tmp` is often a
RAM-backed tmpfs, and a vault dump with inlined attachments will happily exceed it — the
backup would take the machine down instead of failing politely. The staging directory is
removed by an `EXIT` trap, so a failed run does not leave it behind.

---

## Nightly Backup Cron

Add to the Pi's crontab (`crontab -e` as the user running Docker):

```cron
# Daily backup at 02:30, log to file
30 2 * * * /home/pi/home-services/home-drive/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1

# Hourly health check
0 * * * * /home/pi/home-services/home-drive/scripts/healthcheck.sh >> /var/log/homedrive-health.log 2>&1
```

Logs rotate themselves (cron output); use `logrotate` for long-term log management:

```
# /etc/logrotate.d/homedrive
/var/log/homedrive-*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

---

## Backup Configuration

All backup settings live in `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_DEST` | `$DATA_PATH/backups` | Where archives are stored |
| `BACKUP_KEEP` | `7` | How many daily archives to keep |
| `BACKUP_INCLUDE_FILES` | `false` | Include `$DATA_PATH/files/` in the archive (needs `rsync`) |
| `RCLONE_REMOTE` | *(empty)* | rclone remote name for off-Pi copies |

Host packages the script uses: `jq` and `tar` are required, `sqlite3` is strongly
recommended (without it the FileBrowser database is copied with `cp`, which can catch it
mid-write), and `rsync` is needed only for `BACKUP_INCLUDE_FILES=true`.

```bash
sudo apt-get install -y jq sqlite3 rsync
```

### Exit status

`backup.sh` exits **non-zero** if any database failed to dump, if a dump came back
truncated, or if the rclone push failed — so cron mails you even when `NTFY_URL` is not
set. A dump that is not valid CouchDB JSON is discarded rather than archived: an archive
full of empty files that looks like a successful backup is worse than no archive at all.

`healthcheck.sh` independently warns when the newest archive is more than 26 hours old and
fails at 48 hours, which is what actually catches a cron job that quietly stopped running.

---

## Off-Pi Backup with rclone

For a 3-2-1 backup (2 local copies, 1 remote), configure rclone to push archives to
cloud storage (Backblaze B2, S3, Dropbox, etc.):

```bash
# Install rclone
curl https://rclone.org/install.sh | sudo bash

# Configure a remote (interactive wizard)
rclone config

# Test it
rclone lsd myremote:

# Set in .env
RCLONE_REMOTE=myremote
```

The `backup.sh` script will push each new archive automatically.

---

## Restore Procedure

```bash
# List available archives
ls -lh $DATA_PATH/backups/

# Restore from a specific archive
bash scripts/restore.sh /mnt/data/backups/homedrive_20240101_023000.tar.gz
```

What the restore script does:
1. Extracts the archive into `$DATA_PATH/tmp/` (handles both the current flat layout and
   the older wrapper-directory layout).
2. Recreates each CouchDB database and bulk-inserts documents in batches of 200
   (`RESTORE_BATCH_SIZE`), so a multi-gigabyte vault does not exhaust RAM in one POST.
   Deleted-document rows are skipped and attachments are normalised back to
   `{content_type, data}` before being pushed.
3. Replaces the FileBrowser SQLite database, stopping the container first and keeping the
   previous database as `filebrowser.db.pre-restore.<timestamp>`.
4. Copies the archive's config files to `$DATA_PATH/restored-config-<timestamp>/` for you
   to diff — it never overwrites your live `config/`.

It exits non-zero if any database or batch failed.

**System databases are not restored.** `_users`, `_replicator` and `_global_changes` are
skipped: CouchDB recreates them on a fresh `single_node` start, and `_users` cannot be
restored via `_bulk_docs` anyway because its password hashes are instance-specific. If you
created extra CouchDB users beyond the admin, recreate them in Fauxton at
`https://<host>.<tailnet>.ts.net:8443/_utils/`.

### Full Pi Restore (after hardware failure)

1. Flash a fresh microSD / NVMe with Raspberry Pi OS Lite 64-bit.
2. Re-attach the external SSD (data should still be intact).
3. Run `scripts/install.sh` (which also re-mounts the drive from fstab).
4. Re-create `.env` with your secrets.
5. Start the stack: `docker compose up -d`
6. Run `scripts/restore.sh <archive>` to restore CouchDB and FileBrowser DB.

If the external SSD is also gone (hardware failure + data loss), restore from the
rclone remote:

```bash
rclone copy myremote:homedrive-backups/ /mnt/data/backups/
bash scripts/restore.sh /mnt/data/backups/<latest archive>
```

---

## 3-2-1 Backup Strategy

| Copy | Where | How |
|------|-------|-----|
| 1st | External SSD attached to Pi (live data) | Always current |
| 2nd | `$DATA_PATH/backups/` on same SSD | Nightly `backup.sh`, rotate 7 days |
| 3rd | Cloud (Backblaze B2, etc.) | rclone push from `backup.sh` |

For extra safety, add a second USB drive and use `rsync` or a second rclone remote to
create a 4th local copy on the Pi's shelf.

---

## What Is Not Backed Up (and Why)

- **`.env`** — contains secrets. Store it in a password manager or encrypted file.
- **Docker images** — pulled fresh from Docker Hub on any restore.
- **Tailscale state volume** — the container will re-authenticate with your auth key on next start.
- **FileBrowser files (`$DATA_PATH/files/`)** — opt-in via `BACKUP_INCLUDE_FILES=true`. For large drives this can take hours, and it lands on the same disk; a dedicated `rclone sync`/`rsync` job to another device is the better answer.
- **CouchDB system databases (`_users`, `_replicator`, `_global_changes`)** — recreated automatically on a fresh start. Extra CouchDB users must be recreated by hand.
