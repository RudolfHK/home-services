(function () {
  "use strict";

  const POLL_MS = 5000;

  function formatBytes(n) {
    if (n == null) return "–";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return `${v.toFixed(1)} ${units[i]}`;
  }

  function formatUptime(seconds) {
    if (seconds == null) return "–";
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  }

  async function fetchJSON(url, opts) {
    const res = await fetch(url, opts);
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json();
  }

  // ── System stats ────────────────────────────────────────────────────
  async function refreshStats() {
    try {
      const s = await fetchJSON("/api/system/stats");
      document.getElementById("stat-cpu").textContent = s.cpu_percent != null ? `${s.cpu_percent.toFixed(0)}%` : "–";
      document.getElementById("stat-temp").textContent = s.cpu_temp_c != null ? `${s.cpu_temp_c.toFixed(1)}°C` : "n/a";
      document.getElementById("stat-ram").textContent = `${s.ram.percent.toFixed(0)}% of ${formatBytes(s.ram.total)}`;
      document.getElementById("stat-disk").textContent = s.disk_media
        ? `${formatBytes(s.disk_media.used)} / ${formatBytes(s.disk_media.total)}`
        : "not mounted";
      document.getElementById("stat-uptime").textContent = formatUptime(s.uptime_seconds);
    } catch (err) {
      console.warn("stats refresh failed:", err);
    }
  }

  // ── Services ────────────────────────────────────────────────────────
  function statusLabel(status) {
    return { running: "Running", degraded: "Degraded", partial: "Partial", stopped: "Stopped", error: "Error" }[status] || status;
  }

  function buildCard(service) {
    const card = document.createElement("div");
    card.className = "card";

    const header = document.createElement("div");
    header.className = "card-header";

    const title = document.createElement("div");
    title.className = "card-title";
    const dot = document.createElement("span");
    dot.className = `dot dot-${service.status}`;
    const name = document.createElement("span");
    name.textContent = service.label;
    title.appendChild(dot);
    title.appendChild(name);

    const statusEl = document.createElement("span");
    statusEl.className = "status-label";
    statusEl.textContent = statusLabel(service.status);

    header.appendChild(title);
    header.appendChild(statusEl);
    card.appendChild(header);

    const desc = document.createElement("div");
    desc.className = "card-desc";
    desc.textContent = service.description;
    card.appendChild(desc);

    const containers = document.createElement("div");
    containers.className = "card-containers";
    service.containers.forEach((c) => {
      const line = document.createElement("div");
      line.textContent = `${c.container}: ${c.state}${c.health ? ` (${c.health})` : ""}`;
      containers.appendChild(line);
    });
    card.appendChild(containers);

    const actions = document.createElement("div");
    actions.className = "card-actions";

    const openBtn = document.createElement("button");
    openBtn.textContent = "Open";
    openBtn.addEventListener("click", () => window.open(service.url, "_blank"));
    actions.appendChild(openBtn);

    if (service.manageable) {
      const startBtn = document.createElement("button");
      startBtn.textContent = "Start";
      startBtn.addEventListener("click", () => runAction(service.id, "start"));

      const stopBtn = document.createElement("button");
      stopBtn.textContent = "Stop";
      stopBtn.addEventListener("click", () => runAction(service.id, "stop"));

      const restartBtn = document.createElement("button");
      restartBtn.textContent = "Restart";
      restartBtn.addEventListener("click", () => runAction(service.id, "restart"));

      actions.appendChild(startBtn);
      actions.appendChild(stopBtn);
      actions.appendChild(restartBtn);
    }

    const logsBtn = document.createElement("button");
    logsBtn.textContent = "Logs";
    logsBtn.addEventListener("click", () => openLogs(service.id, service.label));
    actions.appendChild(logsBtn);

    card.appendChild(actions);
    return card;
  }

  async function refreshServices() {
    try {
      const data = await fetchJSON("/api/services");
      const container = document.getElementById("services");
      container.innerHTML = "";
      data.services.forEach((s) => container.appendChild(buildCard(s)));
    } catch (err) {
      console.warn("services refresh failed:", err);
    }
  }

  async function runAction(id, action) {
    try {
      await fetchJSON(`/api/services/${id}/${action}`, { method: "POST" });
    } catch (err) {
      alert(`${action} failed: ${err.message}`);
    }
    refreshServices();
  }

  // ── Logs modal ──────────────────────────────────────────────────────
  const modal = document.getElementById("log-modal");
  document.getElementById("log-modal-close").addEventListener("click", () => modal.classList.add("hidden"));

  async function openLogs(id, label) {
    document.getElementById("log-modal-title").textContent = `${label} — logs`;
    document.getElementById("log-modal-body").textContent = "Loading…";
    modal.classList.remove("hidden");
    try {
      const data = await fetchJSON(`/api/services/${id}/logs?lines=200`);
      document.getElementById("log-modal-body").textContent = data.lines.join("\n") || "(no output)";
    } catch (err) {
      document.getElementById("log-modal-body").textContent = `Failed to load logs: ${err.message}`;
    }
  }

  // ── Init ────────────────────────────────────────────────────────────
  refreshServices();
  refreshStats();
  setInterval(refreshServices, POLL_MS);
  setInterval(refreshStats, POLL_MS);
})();
