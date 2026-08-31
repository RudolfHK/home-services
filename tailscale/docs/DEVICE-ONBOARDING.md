# Device onboarding — approving a new device, safely

How to add a new personal device (a phone, a laptop) so it can reach
home-drive, PiTune, and PiHub from anywhere, while keeping out anything you
didn't explicitly approve.

## What Tailscale actually checks, and what it doesn't

Tailscale has no concept of "was this device on my home Wi-Fi during
setup" — a device authenticates with your login (or an auth key) and joins
the tailnet regardless of where it physically is. If you're picturing a
literal network-location check, that isn't a real Tailscale feature, and
nothing below fakes one.

What *does* exist, and what this stack actually relies on:

1. **Device approval** (tailnet-wide setting) — a new device sits in a
   pending state until you, the admin, approve it in the console. It has
   no access to anything else on the tailnet before that.
2. **Tag ownership** (`../acl-policy.hujson`'s `tagOwners`) — only your own
   login can apply `tag:approved-device` to a machine. A device cannot
   grant itself access; only you can.
3. **The ACL policy itself** — even an approved, tagged device can only
   reach the specific server tag(s) it's granted, on the specific port(s)
   each stack's own `tailscale serve` answers on — see
   `../acl-policy.hujson`'s per-service rules. Nothing else, including
   every other port a service happens to have open on the LAN.

Combining these three gives you the practical property you're actually
after — "only devices I've personally signed off on can reach my stuff,
and only the one HTTPS endpoint each stack exposes" — it just isn't
enforced by checking the device's location; it's enforced by requiring
your explicit action twice (approve, then tag) before anything works.

## The recommended workflow

Doing the *initial* enrollment while on your home Wi-Fi isn't required by
Tailscale, but it's still good practice: it's the moment you're physically
present with the device, so it's the easiest point to actually verify "this
is genuinely my phone" before deciding to approve it. Nothing stops you from
approving a device that enrolled from anywhere, but a request to approve a
device you weren't expecting, sitting in the console while you're away from
home, is exactly the kind of thing device approval is designed to let you
catch and reject instead.

### 1. One-time tailnet setup

1. **Settings → Device management → "Require approval for new devices"** —
   turn this on. (https://login.tailscale.com/admin/settings/device-management)
   **Verify it actually saved**: the toggle should show enabled/blue on a
   page reload, not just right after you clicked it. The real proof comes
   in step 2 of "Adding a new personal device" below — a freshly-added
   device should show up in the Machines list as **waiting for approval**,
   not already connected. If a new device is immediately usable instead,
   the setting didn't take — go back and re-check it before relying on it.
2. **Access controls** — paste in `../acl-policy.hujson`, with your own
   login substituted for every `REPLACE-ME-your-login@example.com`. Save.
3. **Each Pi** running one of these stacks needs its own server tag —
   `tag:home-drive-server`, `tag:pitune-server`, or `tag:pihub-server`
   respectively (never the same tag for two different Pis). Set it via
   that Pi's own `.env` (e.g. `TS_EXTRA_ARGS=--advertise-tags=tag:pitune-server`)
   before its first `tailscale up`, or apply it afterwards from the admin
   console's device list. A Pi with no tag matches none of the ACL's rules
   and is unreachable, same as an untagged client device.

### 2. Adding a new personal device

1. Install the Tailscale app on the device, ideally while on your home
   Wi-Fi (see above for why "ideally" and not "required").
2. Sign in with your own Tailscale account.
3. **Go approve it**: https://login.tailscale.com/admin/machines — find
   the new device, click **Approve**. Until you do this, it has no access
   to anything, regardless of what network it's on.
4. **Tag it**: on that same device's row, add `tag:approved-device` (or
   run `tailscale up --advertise-tags=tag:approved-device` from the device
   itself, if your `tagOwners` setup allows self-tagging — the template
   policy only lists your own login, so from the console is simpler).
   `tag:approved-device` grants all three services at once (see
   `../acl-policy.hujson`) — for a device that should only ever reach one
   of them (a guest you're handing PiTune to, say, not your personal
   Nextcloud), don't use this tag. Instead add a narrower one to
   `tagOwners` (e.g. `tag:approved-device-pitune`) with its own single ACL
   rule against just `tag:pitune-server`, and tag their device with that.
5. It can now reach `https://<pi-hostname>.<tailnet>.ts.net/` for every Pi
   whose server tag that device's tag is granted against.

### Revoking a device

Remove `tag:approved-device` from it, or delete it from the tailnet
entirely (https://login.tailscale.com/admin/machines → **⋯** → **Delete**).
Either way, the ACL's deny-by-default means it immediately loses access —
no restart, no redeploy, takes effect live.

## Verifying it actually took effect

From an *unapproved* or untagged device (or by temporarily untagging one
you control), confirm you get a connection failure, not just a slow one —
`tailscale ping <pi-hostname>` should fail outright once untagged. A
timeout that "eventually" succeeds anyway usually means the ACL didn't save
correctly rather than a network issue; re-check the console's Access
controls page for a save error.
