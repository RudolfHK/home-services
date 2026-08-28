# Obsidian Sync Guide

Two ways to sync your Obsidian vault across phone and desktop using this stack.

---

## Option A (Recommended): Self-Hosted LiveSync via CouchDB

**Obsidian Self-hosted LiveSync** is a community plugin that syncs vault content in
real time using CouchDB as a relay. It works across iOS, Android, macOS, Windows, and
Linux — any device running Tailscale can sync.

### How It Works

```
Obsidian (desktop)  ──┐
                       ├──→  CouchDB on Pi  ──→  syncs to all devices
Obsidian (phone)   ──┘
```

Each device pushes changes to CouchDB; CouchDB pushes them back to other devices. No
peer-to-peer connection needed — devices only need to reach the Pi via Tailscale.

---

### Step 1: Create the CouchDB Database

Open the Fauxton admin UI:
```
https://homepi.<tailnet>.ts.net:8443/_utils/
```

1. Log in with `COUCHDB_USER` / `COUCHDB_PASSWORD` from your `.env`.
2. Click **Create Database**.
3. Name it `obsidian` (or whatever you set `COUCHDB_OBSIDIAN_DB` to in `.env`).
4. Leave **Partitioned** unchecked.
5. Click **Create**.

---

### Step 2: Install the Plugin

In Obsidian on each device:
1. Settings → Community Plugins → turn off Safe Mode if prompted.
2. Browse → search for **"Self-hosted LiveSync"** → Install → Enable.

---

### Step 3: Configure the Plugin (Desktop)

Settings → Self-hosted LiveSync → **Setup wizard** (recommended for first device):

| Setting | Value |
|---------|-------|
| URI | `https://homepi.<tailnet>.ts.net/couchdb/` |
| Username | value of `COUCHDB_USER` in `.env` |
| Password | value of `COUCHDB_PASSWORD` in `.env` |
| Database name | `obsidian` (must match what you created above) |
| End-to-end encryption passphrase | any strong passphrase (all devices must use the same one) |

Click **Check database configuration** — it should show green for CORS and chunked sync.

Enable **LiveSync** mode (not Periodic Sync or On-save only) for real-time sync.

---

### Step 4: Configure the Plugin (Phone)

The easiest way is to use the **copy setup URI** feature:

1. On the desktop plugin settings page, click **Copy setup URI**.
2. On your phone, open the same vault (or create a new empty vault).
3. Install Self-hosted LiveSync on the phone.
4. In the plugin settings → **Receive setup URI** → paste the URI from step 1.
5. The phone will auto-fill all settings.

---

### Step 5: Verify Sync

Make a small change (add a character to a note) on one device and watch it appear on
the other within a few seconds.

Check the plugin's **Sync Status** panel (ribbon icon) for live sync state and errors.

---

### Chunk and Performance Settings

For large vaults with many binary attachments, adjust in the plugin settings:

| Setting | Recommended value |
|---------|-------------------|
| Chunk size | 50 (default) |
| Max file size to sync | 50 MB |
| Use history | Off (saves disk space) |
| Batch size | 25 |

---

### Troubleshooting LiveSync

**"CORS error" in browser console or plugin status:**
- Check `config/couchdb/zz-homedrive.ini` includes `app://obsidian.md` and `capacitor://localhost` in the `origins` list.
- Restart CouchDB: `docker compose restart couchdb`

**"Conflict" badges on notes:**
- This happens if two devices edited the same note while offline. Open the note — the plugin shows a diff and lets you resolve it.

**Sync stopped after phone battery saver:**
- iOS and Android kill background apps aggressively. Open Obsidian and the plugin will resume syncing immediately.

---

## Option B: Folder Sync via FileBrowser / WebDAV

Store the vault as a regular folder under the FileBrowser root
(`/mnt/data/files/ObsidianVault/`). Sync it using one of:

### Obsidian Git (desktop)
- Install the **Obsidian Git** community plugin.
- Point the vault at a git repo (local NAS, Gitea on the Pi, or a private GitHub repo).
- Auto-commit on a timer.

**Pros:** Full version history, no extra backend.  
**Cons:** Manual conflict resolution; doesn't work well on iOS (no git on iOS without
extra setup).

### Folder mount via WebDAV (desktop + Android)
- Use a WebDAV client to mount the FileBrowser share:
  - **macOS:** Finder → Go → Connect to Server → `https://homepi.<tailnet>.ts.net/` (FileBrowser has a WebDAV endpoint at `/api/raw/`)
  - **Android:** DAVx⁵ + a Files app that supports WebDAV.
  - **iOS:** Files app → Connect to Server → WebDAV.
- Open the vault folder from within Obsidian.

**Pros:** Simple, no extra plugins.  
**Cons:** No real-time sync — you need to manually sync before/after editing on each device.

---

## Comparison

| Feature | LiveSync (Option A) | FileBrowser / Git (Option B) |
|---------|--------------------|-----------------------------|
| Real-time sync | ✅ | ❌ |
| iOS support | ✅ | Limited |
| Conflict handling | ✅ built-in | Manual |
| Requires CouchDB | ✅ | ❌ |
| End-to-end encryption | ✅ | Depends on git config |
| Version history | Plugin option | ✅ (git) |

For a multi-device setup with phone sync, **Option A (LiveSync) is strongly recommended**.
