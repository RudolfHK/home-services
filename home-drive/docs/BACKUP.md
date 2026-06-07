# Backup Guide

---

## What Gets Backed Up

| Data | Location on Pi | What the backup contains |
|------|---------------|--------------------------|
| FileBrowser files | `$DATA_PATH/files/` | Your documents, photos, etc. (optional — large) |
| FileBrowser config / users | `$DATA_PATH/filebrowser/filebrowser.db` | User accounts, shares, audit log |
| CouchDB Obsidian vault | `$DATA_PATH/couchdb/` | All synced Obsidian notes and attachments |
| Stack config files | `config/` in the project dir | FileBrowser + CouchDB config |

The `.env` file (secrets) is **not** included in the backup archive. Store it separately
(e.g. in a password manager).

---

## Nightly Backup Cron

Add to the Pi's crontab (`crontab -e` as the user running Docker):

```cron
# Daily backup at 02:30, log to file
30 2 * * * /home/pi/homedrive-pi/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1

# Hourly health check
0 * * * * /home/pi/homedrive-pi/scripts/healthcheck.sh >> /var/log/homedrive-health.log 2>&1
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
| `RCLONE_REMOTE` | *(empty)* | rclone remote name for off-Pi copies |

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
1. Extracts the archive.
2. Recreates each CouchDB database and bulk-inserts documents.
3. Replaces the FileBrowser SQLite database (stops/starts the container).
4. Prints instructions for any manual steps.

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
- **FileBrowser files (`$DATA_PATH/files/`)** — backed up optionally (uncomment the `rsync` line in `backup.sh`). For large drives this can take hours; consider a dedicated `rsync` job instead.
