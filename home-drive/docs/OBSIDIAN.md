# Obsidian Sync Guide

---

## Read this first: this stack offers two different things

They look similar, and they are not interchangeable. Almost every "my changes don't sync"
problem comes from doing one while believing you're doing the other.

| | **Option A: LiveSync** | **Option B: FileBrowser / WebDAV** |
|---|---|---|
| What it is | A real sync engine | A file manager with a web UI |
| Where the vault lives | In **CouchDB**, as thousands of small documents | As a folder on the SSD |
| Who moves changes | The Obsidian plugin, continuously, in both directions | **You. By hand. Every time.** |
| Edit on device A → appears on device B | Automatically, in seconds | Only after you manually re-download it |

> ### FileBrowser is not Dropbox
>
> Uploading your vault folder to `https://<hostname>.<tailnet>.ts.net/` and downloading it on
> another device is a **one-time file transfer**. There's no sync agent on your devices
> watching that folder. Nothing uploads your edits. Nothing pushes them anywhere.
>
> If you've uploaded your vault to the file browser and downloaded it on both devices, you
> now have two independent copies that will drift apart from the moment you start editing.
> That's the expected behaviour of a file server, not a bug.
>
> **Real sync needs Option A.** The file browser has exactly one role in that process: a
> convenient bucket for moving a vault between devices *once*, during the initial merge.

---

## Option A (Recommended): Self-Hosted LiveSync via CouchDB

### How it actually works

```
   Obsidian on desktop                     Obsidian on phone
   ┌───────────────────┐                   ┌───────────────────┐
   │ vault on local    │                   │ vault on local    │
   │ disk              │                   │ storage           │
   │   ▲            │  │                   │  │            ▲   │
   │   │ LiveSync   │  │                   │  │  LiveSync  │   │
   │   │ plugin     ▼  │                   │  ▼   plugin   │   │
   └───────────────────┘                   └───────────────────┘
            ▲   │                                   │   ▲
            │   └───────────┐           ┌───────────┘   │
            │               ▼           ▼               │
            │        ╔══════════════════════════╗       │
            └────────║   CouchDB on the Pi      ║───────┘
                     ║   database: "obsidian"   ║
                     ╚══════════════════════════╝
```

Four things follow from this diagram, and they explain most confusion:

1. **The vault still lives on each device.** CouchDB holds a synchronised copy as documents,
   not as `.md` files. You will never browse your notes as files on the server.
2. **FileBrowser is not in this picture at all.** `/mnt/data/files/` plays no part in LiveSync.
3. **The plugin does all the work**, and only while Obsidian is open and the plugin is enabled.
4. **There is no "create new vault / connect existing" choice.** That's Obsidian's paid Sync
   service, not this plugin. LiveSync syncs *the vault it's installed in*: one vault, one
   database. If you went looking for that option and couldn't find it, this is why.

The equivalent decision is made differently:

> **One device seeds the database. Every other device starts from an empty vault and fetches.**

### Prerequisites

Confirm all of these before touching the plugin:

```bash
bash scripts/health-monitor.sh --verbose
```

`couchdb: /_up` and `couchdb: admin credentials` must both be `[OK]`.

Each device must also be signed in to the tailnet and connected. On the device itself, not on
the Pi:

```
tailscale status        # must list your Pi, and this device must not be "offline"
```

> **Commercial VPNs break this.** A full-tunnel VPN captures the default route, and Tailscale
> traffic never reaches the Pi. Symptoms range from `ERR_CONNECTION_CLOSED` in the browser to
> LiveSync silently failing to connect. Disconnect the VPN, or configure it to exclude the
> `100.64.0.0/10` range.

---

## Part 1: The seed device

### 1.1 Choose the seed

Pick the device whose vault is fullest and most current. Usually the desktop. Everything else
becomes a copy of it.

### 1.2 Back up **both** vaults

Not optional. Two steps in this guide are destructive, and this backup is the only thing
between a mistake and losing notes.

Copy each vault folder somewhere outside Obsidian, **including the hidden `.obsidian/`
folder** (it holds your plugins, themes and settings).

- Windows: the vault folder is wherever you created it; enable "Hidden items" in Explorer's
  View tab so `.obsidian` is included in the copy.
- Android: Obsidian vaults usually live under `Internal storage/Documents/` or
  `Internal storage/obsidian/`.

### 1.3 Move the other device's vault to the seed device

**This is the one place FileBrowser is used, and it's a one-time transfer, not sync.**

1. On the phone, open `https://<hostname>.<tailnet>.ts.net/` in a browser and log in as
   `admin` with your `FILEBROWSER_ADMIN_PASSWORD`.
2. Create a folder, call it `vault-transfer`.
3. Upload the phone's vault folder into it.
4. On the desktop, open the same URL and download it.

On the Pi that content lands at:

```
/mnt/data/files/vault-transfer/
```

`/mnt/data/files/` is FileBrowser's root, the `/srv` bind mount in `docker-compose.yml`. It's
**not** where LiveSync stores anything, and putting a vault there doesn't make it sync.

Delete `vault-transfer` when the merge is done, so nobody later mistakes it for the live vault.

### 1.4 Merge into one vault

In the seed vault, add the notes that only exist on the other device.

- **Filename collisions are silent data loss.** Two different `Daily Note.md` files will
  overwrite one another. Rename one first, `Daily Note (phone).md`, then reconcile by hand.
- **Do not merge `.obsidian/` folders.** Keep the seed device's.

Open the merged vault in Obsidian and check it looks right. This is the last point where
fixing a mistake is trivial.

### 1.5 Create the database

Open Fauxton:

```
https://<hostname>.<tailnet>.ts.net:8443/_utils/
```

Log in with `COUCHDB_USER` / `COUCHDB_PASSWORD` from `.env`.

> Fauxton is on port **8443**, at the root. It doesn't work under `/couchdb/`: its bundle
> requests absolute paths like `/_all_dbs`, which on port 443 get routed to FileBrowser.

**Create Database** → name it `obsidian` (must match `COUCHDB_OBSIDIAN_DB` in `.env`) →
leave **Partitioned** unchecked → **Create**.

### 1.6 Install and configure the plugin

Settings → Community Plugins → Browse → **"Self-hosted LiveSync"** → Install → Enable.

Then Settings → Self-hosted LiveSync → **Remote Database configuration**:

| Setting | Value |
|---|---|
| URI | `https://<hostname>.<tailnet>.ts.net/couchdb/` |
| Username | `COUCHDB_USER` from `.env` |
| Password | `COUCHDB_PASSWORD` from `.env` |
| Database name | `obsidian` |
| End-to-end encryption passphrase | Any strong passphrase, **identical on every device** |

Note the URI is the `/couchdb/` path on port **443**, not 8443. Trailing slash included.

Now run the plugin's two built-in checks, in order:

1. **Test Database Connection**, which must succeed. If it fails, jump to Troubleshooting **T4**.
2. **Check database configuration**, which shows a list of CouchDB settings with ✅ or ⚠️. Our
   `config/couchdb/zz-homedrive.ini` already sets all of them, so everything should be green.
   If CORS entries are red, see **T5**.

### 1.7 Push the vault up: direction matters

You're telling the plugin: **local → remote**. The remote is empty; this device has the data.

- In the **setup wizard**, this is the answer to "is this the first device" / "does the remote
  already have data": you're the first device, the remote has nothing.
- Done manually, it's the maintenance action that **sends this device's vault to the server**.
  Depending on plugin version it's labelled **"Rebuild everything"**, **"Overwrite remote"**,
  or appears under 🧰 Maintenance → Rebuild.

> **This is destructive in one direction.** The opposite action, **"Fetch everything from the
> remote"**, replaces *this device's* vault with the server's. On an empty database that
> wipes your notes.
>
> Labels move between plugin versions, so don't trust the label alone. Read which side is the
> source and which is the destination before confirming. You have the backup from 1.2 either
> way.

### 1.8 Verify the data actually arrived

Don't assume. Check the server:

```bash
bash scripts/obsidian-check.sh
```

You want a document count in the thousands for a real vault: LiveSync splits notes into
chunks, so the count is much higher than your note count. `0` documents means nothing was
uploaded and the push didn't happen.

The same thing in Fauxton: the `obsidian` database row shows a document count directly.

**Do not set up the second device until this shows a non-zero count.**

---

## Part 2: Every other device

### 2.1 Start from an EMPTY vault

On the phone, **create a brand-new, empty vault**. Do not install LiveSync into the existing
phone vault.

This is the single most important step. A second vault with existing content that hasn't been
merged into the seed will push its own files up, and you end up with the union of both vaults:
duplicates, collisions, and conflicts to unpick by hand.

Leave the old phone vault alone for now. Delete it only after Part 3 passes.

### 2.2 Carry the settings across with a setup URI

Do not retype the settings on a phone keyboard. One mistyped character in the passphrase
produces a device that connects happily and then can't decrypt anything.

1. **Desktop:** Settings → Self-hosted LiveSync → **Copy setup URI**. It asks for a one-time
   passphrase to encrypt the URI; invent one, you'll type it once on the phone.
2. Send the URI to the phone however is convenient.
3. **Phone:** install Self-hosted LiveSync in the new empty vault, then use **Receive setup
   URI** (or open the `obsidian://` link) and enter that one-time passphrase.

This transfers the URL, credentials, database name **and the E2EE passphrase** in one go.

### 2.3 Pull the vault down: direction matters again

Here the direction is the opposite of 1.7: **remote → local**. The server has the data, this
device is empty.

- In the wizard: this is **not** the first device; the remote **does** have data.
- Manually: **"Fetch everything from the remote"**.

Safe here precisely because the vault is empty, which is why 2.1 matters.

### 2.4 Verify

Your merged notes should appear within seconds to a couple of minutes, depending on vault size.
The plugin's **Sync Status** panel (ribbon icon) shows live progress.

---

## Part 3: Prove sync works in both directions

Do this before deleting anything.

1. On the **desktop**, create a note `sync-test-desktop.md`, type a line, save.
2. Within ~10 seconds it should appear on the **phone**.
3. On the **phone**, create `sync-test-phone.md`, type a line.
4. It should appear on the **desktop**.
5. Edit the *same* note on both, one after the other, and confirm both edits survive.
6. Confirm the server saw it:

```bash
bash scripts/obsidian-check.sh
```

The document count should have grown, and the recent-changes list should name your test files.

Only once **all four directions work** should you delete the old phone vault and the
`vault-transfer` folder in FileBrowser.

---

## Troubleshooting

Start here, always. It tells you whether anything is reaching the server at all:

```bash
bash scripts/obsidian-check.sh
```

### T1: "I uploaded my vault to the file browser and downloaded it on both devices, but changes don't sync"

**Cause:** This is Option B being used as if it were Option A. FileBrowser is a file manager.
It has no client-side agent, it doesn't watch your vault folder, and it will never upload an
edit you make locally. Downloading the same folder twice gives you two independent copies that
diverge immediately.

**Fix:** Set up Option A properly, from Part 1. Treat both downloaded copies as unsynced
vaults: pick one as the seed, merge anything unique from the other into it (1.4), push it to
CouchDB (1.7), and rebuild the second device from an empty vault (2.1).

Don't skip 1.8. Verifying a non-zero document count is what distinguishes "sync configured"
from "sync working".

### T2: LiveSync is configured, but changes never leave the device

Work through these in order:

1. **Is the plugin enabled?** Settings → Community Plugins. Also confirm Restricted/Safe mode
   is off.
2. **Is sync actually switched on?** Settings → Self-hosted LiveSync → **Sync Settings**.
   Enable **LiveSync** for real-time sync. If all of LiveSync / Periodic Sync / Sync on Save
   are off, the plugin is installed and configured and will do nothing at all, which is a very
   common cause of exactly this symptom.
3. **Check the status bar.** The ribbon Sync Status panel shows counts and errors. A permanent
   `⏸` or an error banner means the device has paused itself; see **T3**.
4. **Is the server receiving anything?** Run `scripts/obsidian-check.sh` on the Pi, edit a note,
   run it again. If `doc_count` doesn't move, nothing is being sent and the problem is on that
   device. If it does move but the other device sees nothing, the problem is on the *other*
   device; repeat these checks there.

### T3: One device stopped syncing after you rebuilt on another

**Cause:** "Rebuild everything" marks the remote database as rebuilt. Other devices detect that
their history no longer matches and **deliberately pause** rather than risk mixing two
histories. They usually say so in the Sync Status panel, but it's easy to miss, and from the
outside it looks exactly like "changes stopped syncing".

**Fix:** On each *other* device, run **"Fetch everything from the remote"**. That device
discards its local history and re-adopts the server's.

Make sure that device has nothing unique on it first: anything not yet uploaded is lost.

### T4: "Test Database Connection" fails

| Message | Cause | Fix |
|---|---|---|
| 401 Unauthorized | Wrong credentials | Username/password must match `COUCHDB_USER` / `COUCHDB_PASSWORD` in `.env`. Verify with `bash scripts/health-monitor.sh -v` → "couchdb: admin credentials" is `[OK]` |
| Timeout / cannot connect | Device not on the tailnet, or a VPN is capturing the route | `tailscale status` on that device; disconnect other VPNs |
| 404 Not Found | Database not created, or name mismatch | Create it in Fauxton; the name must match on every device, see **T7** |
| Certificate error | Tailscale HTTPS not enabled | Admin console → DNS → HTTPS Certificates; then `docker exec homedrive-tailscale tailscale cert <hostname>.<tailnet>.ts.net` |
| Works on desktop, fails on phone | Usually CORS | See **T5** |

### T5: CORS errors (typically mobile only)

The origins are already set in `config/couchdb/zz-homedrive.ini`:

```
origins = app://obsidian.md,capacitor://localhost,http://localhost
```

`app://obsidian.md` is desktop Electron, `capacitor://localhost` is iOS/Android.

Remember this file is **staged**, not mounted from the repo. After editing it:

```bash
bash scripts/install.sh --skip-pull      # re-stages the config
docker compose restart couchdb
```

Editing `config/couchdb/zz-homedrive.ini` alone changes nothing until it's re-staged. See the
README section *Why `couchdb-etc/` exists*.

### T6: Devices connect, but notes are empty, garbled, or error on decryption

**Cause:** the E2EE passphrases differ. Each device encrypts with its own, so they can exchange
documents and not read each other's.

**Fix:** Use **Copy setup URI** / **Receive setup URI** (2.2) rather than typing settings by
hand. If it's already gone wrong, fix the passphrase on the second device and
**"Fetch everything from the remote"** there.

### T7: Both devices "work" but never see each other

**Cause:** they're pointed at different databases. Each syncs happily to its own.

**Check** what actually exists on the server:

```bash
bash scripts/obsidian-check.sh
```

If it lists `obsidian` **and** something like `obsidian2`, that's your answer. Fix the
database name in the plugin settings on the odd device out, then
**"Fetch everything from the remote"** there.

### T8: Large files or attachments don't sync

CouchDB is configured with `max_document_size = 50000000` (50 MB) in `zz-homedrive.ini`.
The plugin also has its own **"Max file size to sync"**. Files over either limit are skipped,
usually silently.

For genuinely large media, keep it out of the vault and put it on the home drive
(`/mnt/data/files/`) instead. That's what the file browser is good at.

### T9: Conflict badges on notes

Two devices edited the same note while one was offline. Open the note; the plugin shows a diff
and lets you pick. This is normal and healthy: it means sync is working.

### T10: Sync stops when the phone is in your pocket

iOS and Android suspend background apps aggressively. Open Obsidian and the plugin resumes and
catches up immediately. Nothing to fix.

---

### Chunk and performance settings

For large vaults with many binary attachments:

| Setting | Recommended |
|---|---|
| Chunk size | 50 (default) |
| Max file size to sync | 50 MB (matches CouchDB's `max_document_size`) |
| Use history | Off (saves disk on the SSD) |
| Batch size | 25 |

---

## Option B: Folder sync via FileBrowser / WebDAV

Store the vault as a regular folder under the FileBrowser root
(`/mnt/data/files/ObsidianVault/`).

> This is **not** real-time sync, and downloading the folder onto two devices doesn't make it
> sync. Use one of the mechanisms below, each of which adds an actual sync agent.

### Obsidian Git (desktop)

- Install the **Obsidian Git** community plugin.
- Point the vault at a git repo (a local NAS, Gitea on the Pi, or a private GitHub repo).
- Auto-commit on a timer.

**Pros:** full version history, no extra backend.
**Cons:** manual conflict resolution; poor on iOS.

### WebDAV mount (desktop + Android)

- **macOS:** Finder → Go → Connect to Server → `https://<hostname>.<tailnet>.ts.net/`
  (FileBrowser exposes WebDAV at `/api/raw/`)
- **Android:** DAVx⁵ plus a file app with WebDAV support.
- **iOS:** Files → Connect to Server → WebDAV.

Then open the vault folder from within Obsidian.

**Pros:** simple, no plugins.
**Cons:** the vault is edited over the network; no offline access, and no automatic
reconciliation if two devices edit at once.

---

## Comparison

| Feature | LiveSync (A) | FileBrowser / Git (B) |
|---|---|---|
| Real-time sync | ✅ | ❌ |
| Works offline, syncs later | ✅ | ❌ |
| iOS support | ✅ | Limited |
| Conflict handling | ✅ built-in | Manual |
| Requires CouchDB | ✅ | ❌ |
| End-to-end encryption | ✅ | Depends on setup |
| Version history | Plugin option | ✅ (git) |

For a multi-device setup with phone sync, **Option A is the only one that does what people
mean by "sync"**.
