// The sidebar: system alerts (from SystemStats.systemAlerts) plus a per-
// service failure note when something is unhealthy or has recently
// recovered, and the on-demand "Check for updates" panel.

export function renderAlerts(systemAlerts, services) {
  const container = document.getElementById("alerts");
  container.innerHTML = "";

  const rows = [...systemAlerts];
  services.forEach((s) => {
    if (s.status === "unhealthy" && s.health && s.health.down_since) {
      const downSince = new Date(s.health.down_since * 1000).toLocaleTimeString();
      rows.push({ level: "crit", text: `${s.name} unreachable since ${downSince}` });
    } else if (s.health && s.health.last_down_duration_seconds) {
      const mins = Math.round(s.health.last_down_duration_seconds / 60);
      rows.push({ level: "warn", text: `${s.name} was down for ~${mins}m, recovered` });
    }
  });

  if (!rows.length) {
    const ok = document.createElement("div");
    ok.className = "alert-row";
    ok.textContent = "Everything looks fine.";
    container.appendChild(ok);
    return;
  }

  rows.forEach((alert) => {
    const row = document.createElement("div");
    row.className = `alert-row ${alert.level}`;
    row.textContent = alert.text;
    container.appendChild(row);
  });
}

export function renderUpdates(data) {
  const container = document.getElementById("updates-list");
  container.innerHTML = "";

  if (data.ytdlp) {
    const line = document.createElement("div");
    if (data.ytdlp.current == null) {
      line.textContent = "yt-dlp: version unknown (container not reachable)";
    } else if (data.ytdlp.outdated) {
      line.textContent = `yt-dlp: ${data.ytdlp.current} → ${data.ytdlp.latest} available`;
    } else {
      line.textContent = `yt-dlp: ${data.ytdlp.current} (up to date)`;
    }
    container.appendChild(line);
  }

  Object.entries(data.images || {}).forEach(([container_name, check]) => {
    const line = document.createElement("div");
    if (!check.checked) {
      line.textContent = `${container_name}: ${check.detail || "could not check"}`;
    } else if (check.up_to_date === false) {
      line.textContent = `${container_name}: newer image available`;
    } else if (check.up_to_date === true) {
      line.textContent = `${container_name}: up to date`;
    } else {
      line.textContent = `${container_name}: unknown (no local digest to compare)`;
    }
    container.appendChild(line);
  });

  if (!container.children.length) {
    container.textContent = "No services configured yet.";
  }
}
