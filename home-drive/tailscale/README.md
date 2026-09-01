# `serve.json`

Tailscale serve config, mounted read-only into the optional `tailscale`
container and pointed at by `TS_SERVE_CONFIG`. Only used if you start the
`tailscale` profile; see `../README.md`'s Tailscale section.

## `${TS_CERT_DOMAIN}` is the only variable that gets expanded

`containerboot` (the tailscale image's entrypoint) reads this file and
substitutes exactly one placeholder: `${TS_CERT_DOMAIN}`, replaced with the
node's MagicDNS name (`<TS_HOSTNAME>.<tailnet>.ts.net`).

Arbitrary environment variables like `${TS_HOSTNAME}` or `${TS_TAILNET}` are
**not** expanded. They are passed to `tailscaled` verbatim, producing a serve
config keyed on a hostname that doesn't exist, and a stack that answers
nothing on port 443 while every container reports healthy. Always use
`${TS_CERT_DOMAIN}`.

Note that JSON has no comment syntax and `tailscaled` validates this file, so
keep explanations here rather than adding keys to `serve.json`.

## One port, proxied to nginx by name

Unlike this stack's old CouchDB/FileBrowser setup, there's only one thing to
reach now, so `serve.json` grants exactly `:443` and proxies it to
`nextcloud-web` (the nginx container in `docker-compose.yml`) over the normal
compose network, by its Docker DNS name. `tailscale serve` terminates real
HTTPS on the client's side; nginx itself only ever speaks plain HTTP, both to
`tailscale serve` and directly to LAN clients on `NEXTCLOUD_PORT`. See
`../config/nextcloud/nginx.conf`'s header comment for how it tells the two
apart.

Both `serve`, never `funnel`: reachable from the tailnet only, never the
public internet.
