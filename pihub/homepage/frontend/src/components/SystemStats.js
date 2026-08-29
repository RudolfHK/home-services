// Updates the top-bar stat spans in place (they already exist in
// index.html) and applies warn/crit coloring from settings.yml's
// thresholds — the same numbers home-drive's own monitoring uses, not a
// second, drifting copy of them (see homepage/config/settings.yml).

export function formatBytes(n) {
  if (n == null) return "–";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${units[i]}`;
}

export function formatUptime(seconds) {
  if (seconds == null) return "–";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function levelClass(value, warn, crit) {
  if (value == null) return "";
  if (value >= crit) return "crit";
  if (value >= warn) return "warn";
  return "";
}

export function renderSystemStats(stats, thresholds) {
  const cpuEl = document.getElementById("stat-cpu");
  cpuEl.textContent = stats.cpu_percent != null ? `${stats.cpu_percent.toFixed(0)}%` : "–";

  const tempEl = document.getElementById("stat-temp");
  tempEl.textContent = stats.cpu_temp_c != null ? `${stats.cpu_temp_c.toFixed(1)}°C` : "n/a";
  tempEl.className = `stat-value ${levelClass(stats.cpu_temp_c, thresholds.cpu_temp_warn_c, thresholds.cpu_temp_crit_c)}`;

  const ramEl = document.getElementById("stat-ram");
  ramEl.textContent = `${stats.ram.percent.toFixed(0)}% of ${formatBytes(stats.ram.total)}`;
  ramEl.className = `stat-value ${levelClass(stats.ram.percent, thresholds.ram_warn_percent, thresholds.ram_crit_percent)}`;

  const diskEl = document.getElementById("stat-disk");
  const media = stats.disks && stats.disks.media;
  diskEl.textContent = media ? `${formatBytes(media.used)} / ${formatBytes(media.total)}` : "not mounted";
  diskEl.className = `stat-value ${media ? levelClass(media.percent, thresholds.disk_warn_percent, thresholds.disk_crit_percent) : ""}`;

  document.getElementById("stat-uptime").textContent = formatUptime(stats.uptime_seconds);
}

// Alerts shown in the sidebar health panel — same thresholds, worded as
// sentences instead of just colored numbers.
export function systemAlerts(stats, thresholds) {
  const alerts = [];
  if (stats.cpu_temp_c != null) {
    if (stats.cpu_temp_c >= thresholds.cpu_temp_crit_c) {
      alerts.push({ level: "crit", text: `CPU temperature critical: ${stats.cpu_temp_c.toFixed(1)}°C` });
    } else if (stats.cpu_temp_c >= thresholds.cpu_temp_warn_c) {
      alerts.push({ level: "warn", text: `CPU temperature high: ${stats.cpu_temp_c.toFixed(1)}°C` });
    }
  }
  if (stats.ram.percent >= thresholds.ram_crit_percent) {
    alerts.push({ level: "crit", text: `RAM usage critical: ${stats.ram.percent.toFixed(0)}%` });
  } else if (stats.ram.percent >= thresholds.ram_warn_percent) {
    alerts.push({ level: "warn", text: `RAM usage high: ${stats.ram.percent.toFixed(0)}%` });
  }
  Object.entries(stats.disks || {}).forEach(([mount, disk]) => {
    if (disk.percent >= thresholds.disk_crit_percent) {
      alerts.push({ level: "crit", text: `${mount} drive critical: ${disk.percent}% used` });
    } else if (disk.percent >= thresholds.disk_warn_percent) {
      alerts.push({ level: "warn", text: `${mount} drive getting full: ${disk.percent}% used` });
    }
  });
  return alerts;
}
