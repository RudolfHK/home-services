// Renders one service card. Built from DOM nodes (never innerHTML) so
// nothing from services.yml — names, descriptions — can inject markup,
// the same discipline PiTune's own frontend uses.

const ICONS = {
  music: "🎵",
  film: "🎬",
  photo: "🖼️",
  shield: "🛡️",
  monitor: "📈",
  recipe: "🍲",
  home: "🏠",
  app: "📦",
};

const STATUS_LABEL = {
  running: "Running",
  degraded: "Degraded",
  partial: "Partial",
  unhealthy: "Unhealthy",
  stopped: "Stopped",
  error: "Error",
};

function formatUptime(seconds) {
  if (seconds == null) return null;
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export function buildServiceCard(service, { onAction, onLogs }) {
  const card = document.createElement("div");
  card.className = "card";

  const header = document.createElement("div");
  header.className = "card-header";

  const title = document.createElement("div");
  title.className = "card-title";
  const dot = document.createElement("span");
  dot.className = `dot dot-${service.status}`;
  const icon = document.createElement("span");
  icon.className = "card-icon";
  icon.textContent = ICONS[service.icon] || ICONS.app;
  const name = document.createElement("span");
  name.textContent = service.name;
  title.appendChild(dot);
  title.appendChild(icon);
  title.appendChild(name);

  const statusEl = document.createElement("span");
  statusEl.className = "status-label";
  statusEl.textContent = STATUS_LABEL[service.status] || service.status;

  header.appendChild(title);
  header.appendChild(statusEl);
  card.appendChild(header);

  const desc = document.createElement("div");
  desc.className = "card-desc";
  desc.textContent = service.description;
  card.appendChild(desc);

  const meta = document.createElement("div");
  meta.className = "card-meta";
  const uptimeText = formatUptime(service.uptime_seconds);
  if (uptimeText) {
    const up = document.createElement("span");
    up.textContent = `Up ${uptimeText}`;
    meta.appendChild(up);
  }
  if (service.port) {
    const port = document.createElement("span");
    port.textContent = `:${service.port}`;
    meta.appendChild(port);
  }
  if (service.health && service.health.response_time_ms != null) {
    const rt = document.createElement("span");
    rt.textContent = `${Math.round(service.health.response_time_ms)}ms`;
    meta.appendChild(rt);
  }
  if (service.status === "unhealthy" && service.health && service.health.down_since) {
    const down = document.createElement("span");
    const downSeconds = (Date.now() / 1000) - service.health.down_since;
    down.textContent = `down ${formatUptime(downSeconds) || "<1m"}`;
    meta.appendChild(down);
  }
  card.appendChild(meta);

  const actions = document.createElement("div");
  actions.className = "card-actions";

  const openBtn = document.createElement("button");
  openBtn.textContent = "Open";
  openBtn.addEventListener("click", () => window.open(service.launch_url, "_blank"));
  actions.appendChild(openBtn);

  if (service.manageable) {
    ["start", "stop", "restart"].forEach((action) => {
      const btn = document.createElement("button");
      btn.textContent = action[0].toUpperCase() + action.slice(1);
      btn.addEventListener("click", () => onAction(service.id, action));
      actions.appendChild(btn);
    });
  }

  const logsBtn = document.createElement("button");
  logsBtn.textContent = "Logs";
  logsBtn.addEventListener("click", () => onLogs(service.id, service.name));
  actions.appendChild(logsBtn);

  card.appendChild(actions);
  return card;
}
