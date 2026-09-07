<?php
/**
 * zz-homedrive.config.php — Home Drive additions to the Nextcloud config.
 *
 * Nextcloud reads config.php first, then every *.config.php in the same
 * directory in alphabetical order, so this file loads last and wins. The
 * container's own generated files (config.php, redis.config.php,
 * apcu.config.php …) stay untouched and upgradeable, and everything specific
 * to this deployment lives here.
 *
 * install.sh stages a copy into ${DATA_PATH}/nextcloud/config/ owned by the
 * web user, and only AFTER Nextcloud's first-run install has finished: the
 * image populates that directory from itself only while it is still empty, so
 * seeding this file early would cost you apps.config.php, redis.config.php and
 * the rest. Edit this file, re-run install.sh to apply.
 *
 * Anything already provided through environment variables in docker-compose.yml
 * (trusted domains, overwrite host/protocol, database, Redis) is deliberately
 * NOT repeated here.
 */

$CONFIG = array(

  /**
   * `nextcloud-web` (nginx) is the only thing that ever talks to this
   * container directly — reached either straight from the LAN or, if the
   * optional Tailscale profile is running, via `tailscale serve` proxying
   * to nginx first. Either way, nginx is the proxy in front of PHP, so its
   * IP (always somewhere in this fixed compose subnet — see
   * docker-compose.yml's top-level `networks:` block) is what needs
   * trusting here. Without this, every request appears to come from
   * nginx's own container: the brute-force protection would rate-limit
   * *all* users together after one of them fails a login, and Nextcloud
   * would never see the real scheme (http vs https) nginx resolved for it.
   */
  'trusted_proxies'       => array('10.89.0.0/24'),
  'forwarded_for_headers' => array('HTTP_X_FORWARDED_FOR'),

  /**
   * ── File locking ────────────────────────────────────────────────────────
   * The reason this stack uses Nextcloud at all.
   *
   * Transactional file locking makes a write to a file atomic with respect to
   * every other writer: a second client attempting to write the same file gets
   * a 423 Locked instead of interleaving its bytes with the first one. This is
   * the actual corruption protection, and it is only reliable with a shared
   * memory backend — the Redis container exists for this.
   *
   * Separately, the files_lock app (installed by install.sh) provides
   * *user-visible* exclusive locks: manual "lock this file" in the web UI, and
   * automatic WebDAV LOCK for desktop applications. See ../../README.md.
   */
  'filelocking.enabled'  => true,
  // How long a lock survives without being refreshed. Lower than the default
  // hour: on a home drive, a client that vanished mid-edit blocking a file for
  // 60 minutes is worse than the small risk of an early release.
  'filelocking.ttl'      => 900,

  /**
   * ── Recovery ────────────────────────────────────────────────────────────
   * Locking prevents the common case; versions and the trash bin are what save
   * you from the uncommon one. 'auto' lets Nextcloud shrink these when the
   * drive gets full rather than filling it.
   */
  'versions_retention_obligation'  => 'auto, 90',
  'trashbin_retention_obligation'  => 'auto, 30',

  /**
   * ── Background jobs ─────────────────────────────────────────────────────
   * The nextcloud-cron container runs cron.php every five minutes. Expiring
   * stale locks is one of the jobs it does, so this is not optional here.
   */
  'maintenance_window_start' => 1,   // 01:00 UTC — heavy jobs run then

  /**
   * ── Previews ────────────────────────────────────────────────────────────
   * Preview generation is the single most expensive thing a Pi will do. Keep
   * the sizes modest and the provider list short: the default set includes
   * office and movie providers that spawn external binaries per file.
   */
  'enable_previews'         => true,
  'preview_max_x'           => 1024,
  'preview_max_y'           => 1024,
  'preview_max_filesize_image' => 50,   // MB; skip previews of huge images
  'enabledPreviewProviders' => array(
    'OC\\Preview\\PNG',
    'OC\\Preview\\JPEG',
    'OC\\Preview\\GIF',
    'OC\\Preview\\BMP',
    'OC\\Preview\\HEIC',
    'OC\\Preview\\WEBP',
    'OC\\Preview\\TIFF',
    'OC\\Preview\\MP3',
    'OC\\Preview\\TXT',
    'OC\\Preview\\MarkDown',
  ),

  /**
   * ── Housekeeping ────────────────────────────────────────────────────────
   */
  // Silences a setup warning; used to interpret phone numbers in the contacts.
  'default_phone_region'    => getenv('NEXTCLOUD_PHONE_REGION') ?: 'GB',
  // Do not copy example documents into every new account.
  'skeletondirectory'       => '',
  'log_type'                => 'file',
  'logfile'                 => '/var/www/html/data/nextcloud.log',
  'loglevel'                => 2,          // 2 = warnings and above
  'log_rotate_size'         => 10485760,   // 10 MB, then rotate
  // The updater cannot work on a container image, and offering it invites a
  // broken install. Upgrades happen with `docker compose pull` instead.
  'upgrade.disable-web'     => true,
);
