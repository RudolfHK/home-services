# `serve.json`

Tailscale serve config, mounted read-only into the tailscale container and pointed at by
`TS_SERVE_CONFIG`.

## `${TS_CERT_DOMAIN}` is the only variable that gets expanded

`containerboot` (the tailscale image's entrypoint) reads this file and substitutes exactly
one placeholder: `${TS_CERT_DOMAIN}`, replaced with the node's MagicDNS name
(`<TS_HOSTNAME>.<tailnet>.ts.net`).

Arbitrary environment variables like `${TS_HOSTNAME}` or `${TS_TAILNET}` are **not**
expanded. They are passed to `tailscaled` verbatim, producing a serve config keyed on a
hostname that doesn't exist, and a stack that answers nothing on port 443 while every
container reports healthy. Always use `${TS_CERT_DOMAIN}`.

Note that JSON has no comment syntax and `tailscaled` validates this file, so keep
explanations here rather than adding keys to `serve.json`.

## Why two ports

| Port | Path        | Backend           |
|------|-------------|-------------------|
| 443  | `/`         | FileBrowser :8080 |
| 443  | `/couchdb/` | CouchDB :5984     |
| 8443 | `/`         | CouchDB :5984     |

Tailscale strips the mount-point prefix before proxying, so CouchDB sees `/…` and its REST
API works fine under `/couchdb/`. That's the URI to give Obsidian LiveSync.

Fauxton (CouchDB's admin UI at `/_utils/`) does **not** work under a prefix: its bundle
requests absolute paths such as `/_all_dbs`, which on port 443 resolve to `/` and therefore
hit FileBrowser. Port 8443 serves CouchDB at the root so Fauxton works there:
`https://<host>.<tailnet>.ts.net:8443/_utils/`.

Both ports are `serve`, not `funnel`: reachable from the tailnet only, never the public
internet.
