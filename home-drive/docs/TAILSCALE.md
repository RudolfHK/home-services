# Tailscale Integration Guide

This stack uses Tailscale to provide **private, encrypted access** to FileBrowser and
CouchDB from any device (phone, laptop, or tablet) without opening any ports on your
router or exposing anything to the public internet.

---

## How It Works

```
Device (phone/laptop)
  └─ Tailscale app (WireGuard client)
       └─ Tailscale relay / direct WireGuard tunnel
            └─ Raspberry Pi
                 └─ tailscale container
                      ├─ tailscale serve → HTTPS proxy
                      │    ├─ / → filebrowser:8080
                      │    └─ /couchdb/ → couchdb:5984
                      └─ MagicDNS: homepi.<tailnet>.ts.net
```

The **tailscale container** runs in the same Docker network namespace as the filebrowser
and couchdb containers.  The `tailscale serve` command inside that container creates an
HTTPS reverse proxy that routes incoming tailnet connections to the correct service.

No Docker ports are published to the host. The only way in is through the tailnet.

---

## Approach A (Default): Tailscale as a Docker Service

This is what `docker-compose.yml` implements. The `tailscale/tailscale` Docker image
runs as a service. All other containers share its network with
`network_mode: service:tailscale`.

### 1. Create a Tailscale Account

Go to https://login.tailscale.com and create a free account. The free plan supports up
to 100 devices, which is more than enough for a home setup.

### 2. Generate an Auth Key

1. Go to https://login.tailscale.com/admin/settings/keys
2. Click **Generate auth key**
3. Settings:
   - **Description:** homepi-docker
   - **Reusable:** ✅ (so the container can re-auth after a restart)
   - **Expiry:** 90 days or longer
   - **Tags:** optionally add `tag:server` if you use ACL tags
4. Copy the key. It looks like `tskey-auth-XXXX…`
5. Paste it into `.env` as `TS_AUTHKEY=tskey-auth-...`

### 3. Enable MagicDNS and HTTPS

In the **Tailscale admin console** (https://login.tailscale.com/admin/dns):
1. **MagicDNS** → Enable.  
   Your Pi will be reachable at `homepi.<tailnet>.ts.net`.
2. **HTTPS Certificates** → Enable.  
   Tailscale will automatically provision a Let's Encrypt cert for each machine.
   This gives you `https://homepi.<tailnet>.ts.net` with a valid TLS cert.

### 4. Approve the Node (if required)

If your tailnet requires device approval:
1. Go to https://login.tailscale.com/admin/machines
2. Find `homepi` and click **Approve**.

### 5. `tailscale serve` Configuration

The file `config/tailscale/serve.json` tells Tailscale's built-in HTTPS proxy how to
route requests.  After changes, restart the tailscale container:

```bash
docker compose restart tailscale
```

The current configuration maps:
- `https://homepi.<tailnet>.ts.net/` → FileBrowser (port 8080)
- `https://homepi.<tailnet>.ts.net/couchdb/` → CouchDB API (port 5984)
- `https://homepi.<tailnet>.ts.net:8443/` → CouchDB at the root, for Fauxton

#### `${TS_CERT_DOMAIN}` is the only variable that is expanded

`containerboot` (the tailscale image's entrypoint) substitutes exactly one placeholder in
this file: `${TS_CERT_DOMAIN}`, which it replaces with the node's MagicDNS name.

Anything else, like `${TS_HOSTNAME}` or `${TS_TAILNET}`, is **not** expanded. It reaches
`tailscaled` verbatim, producing a serve config keyed on a hostname that doesn't exist. The
symptom is nasty: every container reports healthy, the node shows up in the admin console,
and nothing answers on port 443. Always use `${TS_CERT_DOMAIN}`.

JSON has no comment syntax and `tailscaled` validates the file, so keep notes in
`config/tailscale/README.md` rather than adding keys to `serve.json`.

#### Why CouchDB is also served on 8443

Tailscale strips the mount-point prefix before proxying, so CouchDB's REST API works fine
under `/couchdb/`. That's the URI to give Obsidian LiveSync.

Fauxton (CouchDB's admin UI) does **not** work under a prefix: its bundle requests absolute
paths such as `/_all_dbs`, which on port 443 resolve to `/` and are routed to FileBrowser
instead. Port 8443 serves CouchDB at the root so Fauxton works there.

To verify the serve config is active:

```bash
docker exec homedrive-tailscale tailscale serve status
```

Both ports use `serve`, not `funnel`, so they're reachable from your tailnet only, never
from the public internet.

---

## Approach B (Alternative): Tailscale on the Host

Install Tailscale directly on the Raspberry Pi OS (not in Docker). The containers still
bind to localhost; Tailscale on the host proxies those ports over the tailnet.

```bash
# Install Tailscale on the host
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate
sudo tailscale up --authkey=tskey-auth-...

# Expose FileBrowser on the tailnet HTTPS endpoint
sudo tailscale serve --bg 8080       # serves / → localhost:8080

# Expose CouchDB on a sub-path
sudo tailscale serve --bg --set-path /couchdb 5984
```

In this mode the Docker containers **must publish ports** to localhost:

```yaml
# In docker-compose.yml, remove network_mode and add:
ports:
  - "127.0.0.1:8080:8080"   # filebrowser
  - "127.0.0.1:5984:5984"   # couchdb
```

Two further changes are required, because approach A binds both services to loopback
*inside the tailscale network namespace*:

- `config/filebrowser/settings.json` → set `"address": "0.0.0.0"`, otherwise FileBrowser
  listens only on the container's own loopback and the published port never connects.
- `config/couchdb/zz-homedrive.ini` → set `bind_address = 0.0.0.0` under `[chttpd]`, or
  simply delete that line so the image's `local.d/10-docker-default.ini` default (`any`)
  applies again.

Losing loopback-only binding is the real cost of approach B: with published ports the
services are reachable from the Pi's LAN interface too, not just the tailnet.

**Pros:** Simpler Docker config, easier to debug.  
**Cons:** Tailscale updates require host-level management; approach A is more portable.

---

## Mobile Setup

1. Install **Tailscale** on your phone (iOS App Store / Google Play).
2. Sign in with the same Tailscale account.
3. Open `https://homepi.<tailnet>.ts.net/` in your mobile browser. FileBrowser loads.
4. For Obsidian LiveSync, the CouchDB URL is:
   `https://homepi.<tailnet>.ts.net/couchdb/`
5. For the CouchDB admin UI, use `https://homepi.<tailnet>.ts.net:8443/_utils/`

---

## Port / URL Reference

| Service          | Tailnet URL                                              | Internal port |
|------------------|----------------------------------------------------------|---------------|
| FileBrowser      | `https://<hostname>.<tailnet>.ts.net/`                    | 8080          |
| CouchDB API      | `https://<hostname>.<tailnet>.ts.net/couchdb/`            | 5984          |
| CouchDB Fauxton  | `https://<hostname>.<tailnet>.ts.net:8443/_utils/`        | 5984          |

Fauxton is on **8443**, not under `/couchdb/`. See the `serve.json` section above.

---

## Troubleshooting

### Container fails to start: `failed to create tun device`

```bash
# Check the tun device exists
ls -la /dev/net/tun

# Load the kernel module
sudo modprobe tun

# Persist it across reboots
echo "tun" | sudo tee /etc/modules-load.d/tun.conf
```

### `tailscale status` shows `NeedsLogin`

The auth key has expired or was not accepted. Generate a new key at
https://login.tailscale.com/admin/settings/keys, update `TS_AUTHKEY` in `.env`, and
restart the container:

```bash
docker compose up -d --force-recreate tailscale
```

### HTTPS cert not working / browser shows certificate error

1. Confirm HTTPS is enabled in the admin console → DNS → HTTPS Certificates.
2. Confirm the machine is approved in Machines.
3. Force cert renewal inside the container:
   ```bash
   docker exec homedrive-tailscale tailscale cert homepi.<tailnet>.ts.net
   ```

### `tailscale serve` not routing correctly

```bash
# Inspect current serve state
docker exec homedrive-tailscale tailscale serve status

# Check the serve.json is mounted correctly
docker exec homedrive-tailscale cat /config/tailscale/serve.json

# Manually reset and re-apply
docker exec homedrive-tailscale tailscale serve reset
docker compose restart tailscale
```
