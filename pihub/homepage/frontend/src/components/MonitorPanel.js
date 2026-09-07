// PiMonitor modal: drive stats load automatically (no token needed, cheap);
// file/user activity are explicit, on-demand actions (see index.html's hint
// text) since a file-activity scan can take real time and both need the
// API token like everything else that isn't a cheap capacity read.

import { formatBytes } from "./SystemStats.js";

const modal = document.getElementById("monitor-modal");
const driveEl = document.getElementById("monitor-drive");
const fileActivityEl = document.getElementById("monitor-file-activity");
const userActivityEl = document.getElementById("monitor-user-activity");

document.getElementById("monitor-modal-close").addEventListener("click", () => modal.classList.add("hidden"));

function renderDrive(drive) {
  if (!drive.available) {
    driveEl.innerHTML = "<h3>Mounted drive</h3><p>Not mounted.</p>";
    return;
  }
  driveEl.innerHTML = "";
  const h3 = document.createElement("h3");
  h3.textContent = "Mounted drive";
  const p = document.createElement("p");
  p.textContent = `${formatBytes(drive.used)} used of ${formatBytes(drive.total)} (${drive.percent}%)`;
  const path = document.createElement("p");
  path.className = "hint";
  path.textContent = drive.path;
  driveEl.append(h3, p, path);
}

function renderFileActivity(data) {
  fileActivityEl.innerHTML = "";
  if (!data.available) {
    fileActivityEl.textContent = "Library path not mounted.";
    return;
  }

  const summary = document.createElement("p");
  const folders = Object.entries(data.by_folder)
    .map(([name, v]) => `${name}: ${v.files} files, ${formatBytes(v.bytes)}`)
    .join(" · ");
  summary.textContent = folders || "(empty)";
  fileActivityEl.appendChild(summary);

  if (data.truncated) {
    const warn = document.createElement("p");
    warn.className = "hint";
    warn.textContent = `Scan stopped early at ${data.scanned_files} files (library is larger than the scan limit); counts above are partial.`;
    fileActivityEl.appendChild(warn);
  }

  const h4 = document.createElement("h4");
  h4.textContent = "Recently changed";
  fileActivityEl.appendChild(h4);

  const list = document.createElement("ul");
  data.recent.forEach((f) => {
    const li = document.createElement("li");
    const when = new Date(f.modified * 1000).toLocaleString();
    li.textContent = `${f.path} (${formatBytes(f.size)}, ${when})`;
    list.appendChild(li);
  });
  fileActivityEl.appendChild(list);
}

function renderNowPlayingList(title, entries) {
  const wrap = document.createElement("div");
  const h4 = document.createElement("h4");
  h4.textContent = title;
  wrap.appendChild(h4);
  if (!entries || !entries.length) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Nothing playing right now.";
    wrap.appendChild(p);
    return wrap;
  }
  const list = document.createElement("ul");
  entries.forEach((e) => {
    const li = document.createElement("li");
    li.textContent = e.user ? `${e.user}: ${e.title}` : e.title;
    list.appendChild(li);
  });
  wrap.appendChild(list);
  return wrap;
}

function renderUserActivity(data) {
  userActivityEl.innerHTML = "";

  const jf = data.jellyfin;
  if (!jf.configured) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Jellyfin: set JELLYFIN_API_KEY in .env to enable.";
    userActivityEl.appendChild(p);
  } else if (!jf.reachable) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Jellyfin: unreachable.";
    userActivityEl.appendChild(p);
  } else {
    userActivityEl.appendChild(renderNowPlayingList("Jellyfin", jf.now_playing));
  }

  const nd = data.navidrome;
  if (!nd.configured) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Navidrome: set NAVIDROME_MONITOR_USER/PASSWORD in .env to enable.";
    userActivityEl.appendChild(p);
  } else if (!nd.reachable) {
    const p = document.createElement("p");
    p.className = "hint";
    p.textContent = "Navidrome: unreachable or credentials rejected.";
    userActivityEl.appendChild(p);
  } else {
    userActivityEl.appendChild(renderNowPlayingList("Navidrome", nd.now_playing));
  }
}

export async function openMonitorPanel(fetchJSON) {
  modal.classList.remove("hidden");
  driveEl.innerHTML = "<h3>Mounted drive</h3><p>Loading…</p>";
  fileActivityEl.textContent = "";
  userActivityEl.textContent = "";

  try {
    renderDrive(await fetchJSON("/api/monitor/drive"));
  } catch (err) {
    driveEl.innerHTML = `<h3>Mounted drive</h3><p>Failed to load: ${err.message}</p>`;
  }
}

export function wireMonitorPanel(fetchJSON) {
  document.getElementById("open-monitor").addEventListener("click", () => openMonitorPanel(fetchJSON));

  document.getElementById("monitor-load-files").addEventListener("click", async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    fileActivityEl.textContent = "Scanning…";
    try {
      renderFileActivity(await fetchJSON("/api/monitor/file-activity"));
    } catch (err) {
      fileActivityEl.textContent = `Failed to load: ${err.message}`;
    } finally {
      btn.disabled = false;
    }
  });

  document.getElementById("monitor-load-users").addEventListener("click", async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true;
    userActivityEl.textContent = "Loading…";
    try {
      renderUserActivity(await fetchJSON("/api/monitor/user-activity"));
    } catch (err) {
      userActivityEl.textContent = `Failed to load: ${err.message}`;
    } finally {
      btn.disabled = false;
    }
  });
}
