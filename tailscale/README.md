# Tailscale — remote access for home-drive, PiTune, and PiHub

This directory isn't a runnable stack — it's the shared tailnet policy and
setup docs for accessing this repo's three network-facing projects from
outside your home network, over Tailscale. Each project keeps its own
Tailscale container and config (`home-drive/config/tailscale/`,
`pitune/tailscale/`, `pihub/tailscale/`); this is only the piece that's
genuinely shared: the access-control policy, and how to onboard a device.

**home-drive already runs on Tailscale exclusively** (no LAN ports at all —
see `../home-drive/docs/TAILSCALE.md`). **PiTune and PiHub are LAN-first by
design** (see their own READMEs) — Tailscale here is an *additional*, opt-in
way to reach them from outside the LAN; their existing direct-LAN ports and
behavior are unchanged.

## Setup order

1. Read [`docs/DEVICE-ONBOARDING.md`](docs/DEVICE-ONBOARDING.md) and do its
   **one-time tailnet setup** (enable device approval, apply
   [`acl-policy.hujson`](acl-policy.hujson)) *before* enabling Tailscale on
   PiTune or PiHub — the ACL is what keeps a freshly-joined node from
   exposing more than intended the moment it comes up.
2. Enable Tailscale per stack you want reachable remotely:
   `home-drive/docs/TAILSCALE.md` (already required, not optional there),
   `pitune/README.md`'s Tailscale section, `pihub/README.md`'s Tailscale
   section.
3. Onboard each personal device per `docs/DEVICE-ONBOARDING.md`'s workflow.

## Why the ACL restricts every server to its own serve port(s) only

Joining a tailnet doesn't hide a node's other listening ports from other
tailnet members — by default, any accepted device can reach any port on any
other accepted device. PiTune and PiHub each publish direct admin ports on
the LAN (Navidrome's `:4533`, Jellyfin's `:8096`, PiHub's raw nginx `:80`
before Tailscale's own HTTPS proxy) specifically so you don't need a VPN
just to create a Navidrome account or run Jellyfin's setup wizard at home.
Without an ACL, once these Pis join the tailnet, every one of those admin
ports would *also* become reachable from anywhere in the tailnet — a much
bigger exposure than "just the app". `acl-policy.hujson` closes this with
one rule per service, each scoped to exactly the port(s) that service's own
`tailscale serve` answers on:

| Server tag | Ports granted | Why |
|---|---|---|
| `tag:home-drive-server` | `443`, `8443`, `9443` | FileBrowser + CouchDB (443), Fauxton at the root (8443), Nextcloud (9443) — see `home-drive/docs/TAILSCALE.md`. |
| `tag:pitune-server` | `443` | The one endpoint `pitune/tailscale/serve.json` answers on. |
| `tag:pihub-server` | `443` | The one endpoint `pihub/tailscale/serve.json` answers on. |

Nothing else is granted on any of these nodes — not Navidrome's `4533`, not
Jellyfin's `8096`, not PiHub's raw nginx `80`.

### One tag per server, not one tag for the whole repo

Earlier drafts of this policy used a single `tag:home-server` for all three
Pis. That has a real cost: it makes it *impossible* to grant a device
access to just one service — tag a device `tag:approved-device` and it can
reach home-drive, PiTune, *and* PiHub, with no way to hand out less. If you
ever want to give a guest device PiTune's music without also handing them
your personal Nextcloud, you need the services to carry different tags in
the first place — which is why each Pi now advertises its own
`tag:*-server` tag, and why `docs/DEVICE-ONBOARDING.md` shows how to add a
second, narrower device tag (e.g. `tag:approved-device-pitune`) scoped to
just one service's ACL rule.

## Why not a literal concurrent-connection cap

The original ask behind this setup included "a hard border that only 2
devices can be connected at once". That's not implemented as a live
counter, deliberately:

- **It doesn't map onto what a "connection" actually is.** One phone
  loading one page opens several simultaneous HTTP connections (the page,
  its assets, a polling request) — capping "2 connections" total would
  throttle a single legitimate device, not "allow 2 devices". Capping by
  distinct source IP is closer, but Tailscale IPs are stable per-device,
  so the count would really be "2 *ever-connected* devices", which is
  exactly what an allowlist already gives you, more simply.
- **It fails in the wrong direction.** A stale connection from a device
  that lost network mid-session would occupy a "slot", potentially
  locking out the very device you meant to allow, until some timeout
  expires. A static allowlist has no such failure mode — revoking access
  is immediate and explicit (untag the device), never accidental.

What you get instead is the thing that actually matches the intent: tag
*exactly* as many devices `tag:approved-device` as you want to ever have
access — two, or any other number — and only those specific devices can
reach anything, full stop. See `acl-policy.hujson`'s own comments and
`docs/DEVICE-ONBOARDING.md` for how to add or revoke one.

If you specifically want a *rate/volume* cap in addition to the allowlist
(protecting against one already-approved device being compromised and
hammering a service, say) — that's a different, complementary control, and
PiTune's and PiHub's own nginx configs do add a modest per-source
`limit_conn` for exactly that. See each project's own README.
