# Backup Guide

---

## What Gets Backed Up

| Data | Location on Pi | In the archive? |
|------|---------------|------------------|
| Nextcloud database | PostgreSQL, inside `homedrive-nextcloud-db` | **Yes**, `pg_dump`ed and validated |
| Nextcloud config | `$DATA_PATH/nextcloud/config/` | **Yes**, archived via `docker exec ... tar` |
| Stack config files | `config/` in the project dir | **Yes** |
| Nextcloud user files | `$DATA_PATH/nextcloud/data/` | **Opt-in**, set `BACKUP_INCLUDE_NEXTCLOUD_DATA=true` |
| `.env` (secrets) | project dir | **No**, see below |

`.env` is deliberately excluded: it holds the admin, database and Redis passwords, and the
archive may be pushed to third-party storage by rclone. Store it separately, in a password
manager or an encrypted file.

Archives are written with mode `0600` and `$DATA_PATH/backups` with mode `0700`: the archive
contains a full database dump, including every share, version and account.

### Why the user files are opt-in

Copying `$DATA_PATH/nextcloud/data/` into the nightly archive turns a 30-second job into one
that can run for hours and needs as much free space again on the same drive, and it's still
just a *second* copy on the *same* disk, which isn't a backup in any meaningful sense. Use
`rclone sync` or a plain `rsync` job to a different device for the file tree, and let
`backup.sh` handle the one thing that can't be copied safely with `cp`: the live PostgreSQL
database.

### Staging location

The dump is staged in `$DATA_PATH/tmp/`, not `/tmp`. On Raspberry Pi OS `/tmp` is often a
RAM-backed tmpfs, and a full-data dump will happily exceed it, taking the machine down
instead of failing politely. The staging directory is removed by an `EXIT` trap, so a failed
run doesn't leave it behind.

---

## Nightly Backup Cron

Add to the Pi's crontab (`crontab -e` as the user running Docker):

```cron
# Daily backup at 02:30, log to file
30 2 * * * /home/pi/home-services/home-drive/scripts/backup.sh >> /var/log/homedrive-backup.log 2>&1
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
| `BACKUP_INCLUDE_NEXTCLOUD_DATA` | `false` | Include the user files. The drive stays **offline** for the whole run; see the main [README.md](../README.md) |
| `RCLONE_REMOTE` | *(empty)* | rclone remote name for off-Pi copies |

While the dump runs, the backup puts Nextcloud into maintenance mode, `pg_dump`s the
database, verifies the dump isn't truncated, and archives `config/`, then takes it back out
of maintenance mode, including on failure or Ctrl-C.

Host packages the script uses: `docker` and `tar` are required, and `rsync` only if you run
a separate job for the user files.

### Exit status

`backup.sh` exits **non-zero** if the database dump failed, if it came back truncated, if
the config archive failed, or if the rclone push failed, so cron mails you even when
`NTFY_URL` isn't set. A dump missing its final "dump complete" marker is discarded rather
than archived: an archive that looks like a successful backup but restores nothing is worse
than no archive at all.

---

## Off-Pi Backup with rclone

For a 3-2-1 backup (2 local copies, 1 remote), configure rclone to push archives to cloud
storage (Backblaze B2, S3, Dropbox, etc.):

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

The `backup.sh` script pushes each new archive automatically.

---

## Restore Procedure

```bash
# List available archives
ls -lh $DATA_PATH/backups/

# Restore from a specific archive
bash scripts/restore.sh /mnt/data/backups/homedrive_20240101_023000.tar.gz
```

What the restore script does:
1. Extracts the archive into `$DATA_PATH/tmp/`.
2. Puts Nextcloud into maintenance mode and restores the PostgreSQL dump with `psql`.
3. Copies the archive's config files to `$DATA_PATH/restored-config-<timestamp>/` for you to
   diff. It never overwrites your live `config/` directory automatically.

It exits non-zero if the database restore failed.

### Full Pi Restore (after hardware failure)

1. Flash a fresh microSD / NVMe with Raspberry Pi OS Lite 64-bit.
2. Re-attach the external SSD (data should still be intact).
3. Run `scripts/mount-drive.sh` (or restore the fstab entry by hand) and `scripts/install.sh`.
4. Re-create `.env` with your secrets.
5. Run `scripts/restore.sh <archive>` to restore the database.

If the external SSD is also gone (hardware failure and data loss), restore from the rclone
remote:

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

For extra safety, add a second USB drive and use `rsync` or a second rclone remote to create
a 4th local copy on the Pi's shelf.

---

## What Is Not Backed Up (and Why)

- **`.env`**: contains secrets. Store it in a password manager or encrypted file.
- **Docker images**: pulled fresh from Docker Hub on any restore.
- **Tailscale state volume**: only relevant if the optional `tailscale` profile is in use;
  the container re-authenticates with a fresh auth key on next start.
- **Nextcloud user files (`$DATA_PATH/nextcloud/data/`)**: opt-in via
  `BACKUP_INCLUDE_NEXTCLOUD_DATA=true`. For large drives this can take hours, and it lands on
  the same disk; a dedicated `rclone sync`/`rsync` job to another device is the better answer.
