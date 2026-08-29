<?php
/**
 * zz-homedrive.config.php — Home Drive additions to the Nextcloud config.
 *
 * Nextcloud reads config.php first, then every *.config.php in the same
 * directory in alphabetical order, so this file loads last and wins. Same
 * pattern as config/couchdb/zz-homedrive.ini — the container's own generated
 * files (config.php, redis.config.php, apcu.config.php …) stay untouched and
 * upgradeable, and everything specific to this deployment lives here.
 *
 * install-drive.sh stages a copy into ${DATA_PATH}/nextcloud/config/ owned by
 * the web user. Edit this file, re-run install-drive.sh to apply.
 *
 * Anything already provided through environment variables in docker-compose.yml
 * (trusted domains, overwrite host/protocol, database, Redis) is deliberately
 * NOT repeated here.
 */

$CONFIG = array(

  /**
   * TLS is terminated by `tailscale serve`, which then proxies to 127.0.0.1.
   * Without trusting that proxy, every request appears to come from localhost:
   * the brute-force protection would then rate-limit *all* users together after
   * one of them fails a login, and the security log would name the wrong host.
   */
  'trusted_proxies'       => array('127.0.0.1', '::1'),
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
   * Separately, the files_lock app (installed by install-drive.sh) provides
   * *user-visible* exclusive locks: manual "lock this file" in the web UI, and
   * automatic WebDAV LOCK for desktop applications. See docs/DRIVE.md.
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
