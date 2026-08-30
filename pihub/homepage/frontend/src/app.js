import { buildServiceCard } from "./components/ServiceCard.js";
import { renderSystemStats, systemAlerts } from "./components/SystemStats.js";
import { renderAlerts, renderUpdates } from "./components/HealthPanel.js";
import { openLogViewer } from "./components/LogViewer.js";

// Fetched once at init from /api/auth/token (a same-origin-only read — see
// that endpoint's own comment in main.py) and attached to every request
// after. Harmless to send on read-only endpoints that don't check it;
// required by the backend on every start/stop/restart/logs call.
let apiToken = "";

async function fetchJSON(url, opts) {
  const headers = { ...(opts && opts.headers), "X-PiHub-Token": apiToken };
  const res = await fetch(url, { ...opts, headers });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json();
}

// ── Theme ───────────────────────────────────────────────────────────────
// settings.yml's theme_default only picks the browser's FIRST visit —
// after that, whatever the user toggled is remembered here and always wins.
const THEME_KEY = "pihub-homepage.theme";
function applyTheme(theme) {
  document.documentElement.setAttribute("data-theme", theme);
  document.getElementById("theme-toggle").textContent = theme === "dark" ? "🌙" : "☀️";
}
function initTheme(defaultTheme) {
  let saved;
  try { saved = localStorage.getItem(THEME_KEY); } catch { saved = null; }
  applyTheme(saved || defaultTheme || "dark");
}
document.getElementById("theme-toggle").addEventListener("click", () => {
  const current = document.documentElement.getAttribute("data-theme") || "dark";
  const next = current === "dark" ? "light" : "dark";
  applyTheme(next);
  try { localStorage.setItem(THEME_KEY, next); } catch { /* private browsing, etc. */ }
});

// ── Clock ───────────────────────────────────────────────────────────────
function tickClock() {
  document.getElementById("clock").textContent = new Date().toLocaleTimeString();
}
setInterval(tickClock, 1000);
tickClock();

// ── State ───────────────────────────────────────────────────────────────
let settings = null;
let lastServices = [];

// ── Services (cards + alerts) ────────────────────────────────────────────
let servicesInFlight = false;
async function refreshServices() {
  // Guards against overlapping polls piling up if a request ever outlasts
  // the poll interval (a slow docker call, a hung request).
  if (servicesInFlight) return;
  servicesInFlight = true;
  try {
    const data = await fetchJSON("/api/services");
    lastServices = data.services;
    const container = document.getElementById("services");
    container.innerHTML = "";
    data.services.forEach((s) => container.appendChild(buildServiceCard(s, { onAction: runAction, onLogs: showLogs })));
    renderAlerts(lastSystemAlerts, lastServices);
  } catch (err) {
    console.warn("services refresh failed:", err);
  } finally {
    servicesInFlight = false;
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

function showLogs(id, label) {
  openLogViewer(id, label, fetchJSON);
}

document.getElementById("start-all").addEventListener("click", async () => {
  try { await fetchJSON("/api/services/start-all", { method: "POST" }); }
  catch (err) { alert(`Start all failed: ${err.message}`); }
  refreshServices();
});
document.getElementById("stop-all").addEventListener("click", async () => {
  if (!confirm("Stop every manageable service?")) return;
  try { await fetchJSON("/api/services/stop-all", { method: "POST" }); }
  catch (err) { alert(`Stop all failed: ${err.message}`); }
  refreshServices();
});

// ── System stats ──────────────────────────────────────────────────────
let statsInFlight = false;
let lastSystemAlerts = [];
async function refreshStats() {
  if (statsInFlight) return;
  statsInFlight = true;
  try {
    const stats = await fetchJSON("/api/system/stats");
    renderSystemStats(stats, settings.thresholds);
    lastSystemAlerts = systemAlerts(stats, settings.thresholds);
    renderAlerts(lastSystemAlerts, lastServices);
  } catch (err) {
    console.warn("stats refresh failed:", err);
  } finally {
    statsInFlight = false;
  }
}

// ── Updates (on demand only — never polled) ──────────────────────────
document.getElementById("check-updates").addEventListener("click", async (e) => {
  const btn = e.currentTarget;
  btn.disabled = true;
  btn.textContent = "Checking…";
  try {
    const data = await fetchJSON("/api/system/updates");
    renderUpdates(data);
  } catch (err) {
    document.getElementById("updates-list").textContent = `Check failed: ${err.message}`;
  } finally {
    btn.disabled = false;
    btn.textContent = "Check for updates";
  }
});

// ── Init ──────────────────────────────────────────────────────────────
async function init() {
  try {
    const auth = await fetchJSON("/api/auth/token");
    apiToken = auth.token || "";
  } catch (err) {
    console.warn("could not fetch API token — mutating actions will fail:", err);
  }

  try {
    settings = await fetchJSON("/api/config/settings");
  } catch {
    settings = {
      title: "PiHub", theme_default: "dark", services_poll_seconds: 12, stats_poll_seconds: 5,
      thresholds: { cpu_temp_warn_c: 70, cpu_temp_crit_c: 80, disk_warn_percent: 75, disk_crit_percent: 90, ram_warn_percent: 85, ram_crit_percent: 95 },
    };
  }
  document.getElementById("page-title").textContent = settings.title || "PiHub";
  document.title = settings.title || "PiHub";
  initTheme(settings.theme_default);

  refreshServices();
  refreshStats();
  setInterval(refreshServices, (settings.services_poll_seconds || 12) * 1000);
  setInterval(refreshStats, (settings.stats_poll_seconds || 5) * 1000);
}

init();
