(function () {
  "use strict";

  // ── MD5 (public domain, Joseph Myers) ─────────────────────────────────
  // Needed for Subsonic's token auth scheme: t = md5(password + salt).
  // Navidrome never sees the raw password over the wire this way, only a
  // salt that changes on every request plus its hash.
  function md5(str) {
    function rh(n) { var j, s = ""; for (j = 0; j <= 3; j++) s += "0123456789abcdef".charAt((n >> (j * 8 + 4)) & 0x0F) + "0123456789abcdef".charAt((n >> (j * 8)) & 0x0F); return s; }
    function ad(x, y) { var l = (x & 0xFFFF) + (y & 0xFFFF); var m = (x >> 16) + (y >> 16) + (l >> 16); return (m << 16) | (l & 0xFFFF); }
    function rl(n, c) { return (n << c) | (n >>> (32 - c)); }
    function cm(q, a, b, x, s, t) { return ad(rl(ad(ad(a, q), ad(x, t)), s), b); }
    function ff(a, b, c, d, x, s, t) { return cm((b & c) | ((~b) & d), a, b, x, s, t); }
    function gg(a, b, c, d, x, s, t) { return cm((b & d) | (c & (~d)), a, b, x, s, t); }
    function hh(a, b, c, d, x, s, t) { return cm(b ^ c ^ d, a, b, x, s, t); }
    function ii(a, b, c, d, x, s, t) { return cm(c ^ (b | (~d)), a, b, x, s, t); }
    function sb(x) {
      var i, nblk = ((x.length + 8) >> 6) + 1, blks = new Array(nblk * 16);
      for (i = 0; i < nblk * 16; i++) blks[i] = 0;
      for (i = 0; i < x.length; i++) blks[i >> 2] |= x.charCodeAt(i) << ((i % 4) * 8);
      blks[i >> 2] |= 0x80 << ((i % 4) * 8);
      blks[nblk * 16 - 2] = x.length * 8;
      return blks;
    }
    var i, x = sb("" + str), a = 1732584193, b = -271733879, c = -1732584194, d = 271733878, olda, oldb, oldc, oldd;
    for (i = 0; i < x.length; i += 16) {
      olda = a; oldb = b; oldc = c; oldd = d;
      a = ff(a, b, c, d, x[i + 0], 7, -680876936); d = ff(d, a, b, c, x[i + 1], 12, -389564586); c = ff(c, d, a, b, x[i + 2], 17, 606105819); b = ff(b, c, d, a, x[i + 3], 22, -1044525330);
      a = ff(a, b, c, d, x[i + 4], 7, -176418897); d = ff(d, a, b, c, x[i + 5], 12, 1200080426); c = ff(c, d, a, b, x[i + 6], 17, -1473231341); b = ff(b, c, d, a, x[i + 7], 22, -45705983);
      a = ff(a, b, c, d, x[i + 8], 7, 1770035416); d = ff(d, a, b, c, x[i + 9], 12, -1958414417); c = ff(c, d, a, b, x[i + 10], 17, -42063); b = ff(b, c, d, a, x[i + 11], 22, -1990404162);
      a = ff(a, b, c, d, x[i + 12], 7, 1804603682); d = ff(d, a, b, c, x[i + 13], 12, -40341101); c = ff(c, d, a, b, x[i + 14], 17, -1502002290); b = ff(b, c, d, a, x[i + 15], 22, 1236535329);
      a = gg(a, b, c, d, x[i + 1], 5, -165796510); d = gg(d, a, b, c, x[i + 6], 9, -1069501632); c = gg(c, d, a, b, x[i + 11], 14, 643717713); b = gg(b, c, d, a, x[i + 0], 20, -373897302);
      a = gg(a, b, c, d, x[i + 5], 5, -701558691); d = gg(d, a, b, c, x[i + 10], 9, 38016083); c = gg(c, d, a, b, x[i + 15], 14, -660478335); b = gg(b, c, d, a, x[i + 4], 20, -405537848);
      a = gg(a, b, c, d, x[i + 9], 5, 568446438); d = gg(d, a, b, c, x[i + 14], 9, -1019803690); c = gg(c, d, a, b, x[i + 3], 14, -187363961); b = gg(b, c, d, a, x[i + 8], 20, 1163531501);
      a = gg(a, b, c, d, x[i + 13], 5, -1444681467); d = gg(d, a, b, c, x[i + 2], 9, -51403784); c = gg(c, d, a, b, x[i + 7], 14, 1735328473); b = gg(b, c, d, a, x[i + 12], 20, -1926607734);
      a = hh(a, b, c, d, x[i + 5], 4, -378558); d = hh(d, a, b, c, x[i + 8], 11, -2022574463); c = hh(c, d, a, b, x[i + 11], 16, 1839030562); b = hh(b, c, d, a, x[i + 14], 23, -35309556);
      a = hh(a, b, c, d, x[i + 1], 4, -1530992060); d = hh(d, a, b, c, x[i + 4], 11, 1272893353); c = hh(c, d, a, b, x[i + 7], 16, -155497632); b = hh(b, c, d, a, x[i + 10], 23, -1094730640);
      a = hh(a, b, c, d, x[i + 13], 4, 681279174); d = hh(d, a, b, c, x[i + 0], 11, -358537222); c = hh(c, d, a, b, x[i + 3], 16, -722521979); b = hh(b, c, d, a, x[i + 6], 23, 76029189);
      a = hh(a, b, c, d, x[i + 9], 4, -640364487); d = hh(d, a, b, c, x[i + 12], 11, -421815835); c = hh(c, d, a, b, x[i + 15], 16, 530742520); b = hh(b, c, d, a, x[i + 2], 23, -995338651);
      a = ii(a, b, c, d, x[i + 0], 6, -198630844); d = ii(d, a, b, c, x[i + 7], 10, 1126891415); c = ii(c, d, a, b, x[i + 14], 15, -1416354905); b = ii(b, c, d, a, x[i + 5], 21, -57434055);
      a = ii(a, b, c, d, x[i + 12], 6, 1700485571); d = ii(d, a, b, c, x[i + 3], 10, -1894986606); c = ii(c, d, a, b, x[i + 10], 15, -1051523); b = ii(b, c, d, a, x[i + 1], 21, -2054922799);
      a = ii(a, b, c, d, x[i + 8], 6, 1873313359); d = ii(d, a, b, c, x[i + 15], 10, -30611744); c = ii(c, d, a, b, x[i + 6], 15, -1560198380); b = ii(b, c, d, a, x[i + 13], 21, 1309151649);
      a = ii(a, b, c, d, x[i + 4], 6, -145523070); d = ii(d, a, b, c, x[i + 11], 10, -1120210379); c = ii(c, d, a, b, x[i + 2], 15, 718787259); b = ii(b, c, d, a, x[i + 9], 21, -343485551);
      a = ad(a, olda); b = ad(b, oldb); c = ad(c, oldc); d = ad(d, oldd);
    }
    return rh(a) + rh(b) + rh(c) + rh(d);
  }
  // Turns a JS string into a byte string (charCodeAt 0-255 only) so non-ASCII
  // passwords still hash correctly instead of silently truncating to 8 bits.
  function utf8(str) { return unescape(encodeURIComponent(str)); }

  // ── Subsonic client (talks to Navidrome via the /rest/ proxy) ─────────
  const SUBSONIC_APP = "pitune";
  const SUBSONIC_VERSION = "1.16.1";

  function randomSalt(len) {
    len = len || 8;
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    let s = "";
    for (let i = 0; i < len; i++) s += chars[Math.floor(Math.random() * chars.length)];
    return s;
  }

  const Subsonic = {
    creds: null,

    load() {
      const raw = localStorage.getItem("pitune.subsonic");
      this.creds = raw ? JSON.parse(raw) : null;
      return this.creds;
    },
    save(user, pass) {
      this.creds = { user, pass };
      localStorage.setItem("pitune.subsonic", JSON.stringify(this.creds));
    },
    clear() {
      this.creds = null;
      localStorage.removeItem("pitune.subsonic");
    },
    authParams() {
      const salt = randomSalt();
      const token = md5(utf8(this.creds.pass + salt));
      return new URLSearchParams({
        u: this.creds.user, t: token, s: salt,
        v: SUBSONIC_VERSION, c: SUBSONIC_APP, f: "json",
      });
    },
    url(endpoint, extra) {
      const params = this.authParams();
      Object.entries(extra || {}).forEach(([k, v]) => params.set(k, v));
      // Relative, not "/rest/...": this page is reached through PiHub's
      // central nginx at /pitune/, and a leading slash resolves against the
      // ORIGIN root instead, landing on homepage's catch-all location / and
      // 404ing there instead of reaching Navidrome at all; the browser
      // resolves an absolute path against the origin, ignoring what path
      // the page itself was actually served from.
      return `rest/${endpoint}.view?${params.toString()}`;
    },
    streamUrl(id) { return this.url("stream", { id }); },
    coverArtUrl(id) { return this.url("getCoverArt", { id, size: 100 }); },
    async call(endpoint, extra) {
      const res = await fetch(this.url(endpoint, extra));
      let data;
      try {
        data = await res.json();
      } catch {
        // Navidrome down, still starting, or the reverse proxy itself
        // returned an HTML error page — not something a JSON body describes.
        throw new Error(`Navidrome returned an unexpected response (HTTP ${res.status})`);
      }
      const body = data["subsonic-response"];
      if (!body || body.status !== "ok") {
        const err = new Error((body && body.error && body.error.message) || "Subsonic request failed");
        // Subsonic error codes 40/41 are the only ones that actually mean
        // "these credentials are wrong" — anything else (rate limited,
        // server error, unsupported client version...) is not a reason to
        // throw away a saved login. See initLibrary()'s use of this flag.
        err.authFailed = !!(body && body.error && [40, 41].includes(body.error.code));
        throw err;
      }
      return body;
    },
    ping() { return this.call("ping"); },
    getArtists() { return this.call("getArtists"); },
    getArtist(id) { return this.call("getArtist", { id }); },
    getAlbum(id) { return this.call("getAlbum", { id }); },
    getRandomSongs(size) { return this.call("getRandomSongs", { size }); },
    getAlbumList2(type, size) { return this.call("getAlbumList2", { type, size }); },
    getStarred2() { return this.call("getStarred2"); },
    star(id) { return this.call("star", { id }); },
    unstar(id) { return this.call("unstar", { id }); },
    getPlaylists() { return this.call("getPlaylists"); },
    getPlaylist(id) { return this.call("getPlaylist", { id }); },
    createPlaylist(name) { return this.call("createPlaylist", { name }); },
    // songIdToAdd is deliberately singular here (one song at a time);
    // Subsonic supports repeating this param to add several at once, but
    // nothing in this app's UI batches adds, so there's only ever one.
    addToPlaylist(playlistId, songId) {
      return this.call("updatePlaylist", { playlistId, songIdToAdd: songId });
    },
  };

  // ── Helpers ─────────────────────────────────────────────────────────
  function formatTime(sec) {
    if (!isFinite(sec) || sec < 0) return "0:00";
    const m = Math.floor(sec / 60);
    const s = Math.floor(sec % 60).toString().padStart(2, "0");
    return `${m}:${s}`;
  }

  // Builds one list row from DOM nodes (never innerHTML) so nothing coming
  // from Navidrome metadata or YouTube search results — titles, thumbnail
  // URLs — can break out of an attribute or inject markup.
  //
  // actions: [{icon, title, onClick, className}], rendered in the order
  // given, each stopping the click from also triggering onClick (the row
  // itself); lets a row offer more than one action (YouTube results get
  // queue AND save; Queue rows just get remove).
  function buildRow({ thumbUrl, icon, title, sub, durationText, onClick, actions }) {
    const li = document.createElement("li");
    li.className = "item-row";

    if (thumbUrl) {
      const img = document.createElement("img");
      img.className = "item-thumb";
      img.src = thumbUrl;
      img.alt = "";
      li.appendChild(img);
    } else {
      const div = document.createElement("div");
      div.className = "item-icon";
      div.textContent = icon || "🎵";
      li.appendChild(div);
    }

    const meta = document.createElement("div");
    meta.className = "item-meta";
    const titleEl = document.createElement("div");
    titleEl.className = "item-title";
    titleEl.textContent = title || "";
    const subEl = document.createElement("div");
    subEl.className = "item-sub";
    subEl.textContent = sub || "";
    meta.appendChild(titleEl);
    meta.appendChild(subEl);
    li.appendChild(meta);

    if (durationText) {
      const dur = document.createElement("div");
      dur.className = "item-duration";
      dur.textContent = durationText;
      li.appendChild(dur);
    }

    (actions || []).forEach(({ icon: actionIcon, title: actionTitle, onClick: actionOnClick, className }) => {
      const btn = document.createElement("button");
      btn.className = className ? `item-action ${className}` : "item-action";
      btn.title = actionTitle || "";
      btn.textContent = actionIcon;
      btn.addEventListener("click", (e) => { e.stopPropagation(); actionOnClick(btn); });
      li.appendChild(btn);
    });

    if (onClick) li.addEventListener("click", onClick);
    return li;
  }

  // ── Player / queue ──────────────────────────────────────────────────
  const audio = document.getElementById("audio");
  let queue = []; // {title, artist, src, source: 'local'|'youtube'}
  let queueIndex = -1;

  function renderQueue() {
    const list = document.getElementById("queue-list");
    list.innerHTML = "";
    queue.forEach((track, i) => {
      const row = buildRow({
        icon: track.source === "youtube" ? "▶" : "🎵",
        title: track.title,
        sub: track.artist,
        onClick: () => playIndex(i),
        actions: [
          // A no-op onClick: this button's real job is pointerdown/move/up
          // (see attachDragHandle below), not a click. Plain HTML5
          // draggable="true" drag-and-drop does not fire on touchscreens at
          // all (notably not in Chrome for Android), which is a real
          // problem for an app meant to be used from a phone; Pointer
          // Events cover mouse, touch and pen with one code path instead.
          { icon: "⠿", title: "Drag to reorder", className: "item-drag-handle", onClick: () => {} },
          {
            icon: "✕", title: "Remove", className: "item-remove",
            onClick: () => {
              queue.splice(i, 1);
              if (i < queueIndex) queueIndex--;
              else if (i === queueIndex) { queueIndex = -1; audio.pause(); audio.removeAttribute("src"); }
              renderQueue();
              renderNowPlaying();
            },
          },
        ],
      });
      if (i === queueIndex) row.classList.add("playing");
      // Reordering below moves these <li> elements directly (list.insertBefore),
      // never rebuilding them mid-drag: a rebuild would drop the pointer
      // capture the drag depends on. _track is how the commit step recovers
      // queue[]'s new order from the DOM afterward, by object identity
      // rather than by position (position is exactly what moved).
      row._track = track;
      list.appendChild(row);
      attachDragHandle(row.querySelector(".item-drag-handle"), row);
    });
  }

  // Live-reorders the DOM as the pointer crosses into another row (so what
  // you see while dragging is already the real order, not a preview),
  // committing queue[]/queueIndex back from the DOM's final order on
  // release. Tracking the "now playing" row by object identity (found via
  // indexOf, not carried as a number) is what keeps it correctly pointing at
  // the same track even when that track is the one just dragged.
  function attachDragHandle(handle, row) {
    let pointerId = null;

    handle.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      pointerId = e.pointerId;
      handle.setPointerCapture(pointerId);
      row.classList.add("dragging");
    });

    handle.addEventListener("pointermove", (e) => {
      if (e.pointerId !== pointerId) return;
      const list = document.getElementById("queue-list");
      const rows = Array.from(list.children);
      const overRow = rows.find((r) => {
        if (r === row) return false;
        const rect = r.getBoundingClientRect();
        return e.clientY >= rect.top && e.clientY <= rect.bottom;
      });
      if (!overRow) return;
      const draggedIsAbove = rows.indexOf(row) < rows.indexOf(overRow);
      list.insertBefore(row, draggedIsAbove ? overRow.nextSibling : overRow);
    });

    const commitDrag = (e) => {
      if (e.pointerId !== pointerId) return;
      pointerId = null;
      const list = document.getElementById("queue-list");
      const playingTrack = queue[queueIndex];
      queue = Array.from(list.children).map((r) => r._track);
      queueIndex = playingTrack ? queue.indexOf(playingTrack) : -1;
      renderQueue(); // rebuilds cleanly so every row's closures match its new index
    };
    handle.addEventListener("pointerup", commitDrag);
    handle.addEventListener("pointercancel", commitDrag);
  }

  function renderNowPlaying() {
    const track = queue[queueIndex];
    document.getElementById("np-title").textContent = track ? track.title : "Nothing playing";
    document.getElementById("np-artist").textContent = track ? (track.artist || "") : "";
  }

  function playIndex(i) {
    if (i < 0 || i >= queue.length) return;
    queueIndex = i;
    audio.src = queue[i].src;
    audio.play().catch((err) => console.warn("Playback failed:", err));
    renderNowPlaying();
    renderQueue();
  }

  function enqueue(track) {
    queue.push(track);
    renderQueue();
    playIndex(queue.length - 1);
  }

  // Adds without touching playback, unlike enqueue() above, for a
  // dedicated "add to queue" action distinct from "play this now".
  function addToQueue(track) {
    queue.push(track);
    renderQueue();
  }

  document.getElementById("btn-playpause").addEventListener("click", () => {
    if (!audio.src) return;
    if (audio.paused) audio.play(); else audio.pause();
  });
  document.getElementById("btn-next").addEventListener("click", () => playIndex(queueIndex + 1));
  document.getElementById("btn-prev").addEventListener("click", () => {
    if (audio.currentTime > 3) { audio.currentTime = 0; return; }
    playIndex(queueIndex - 1);
  });

  // ── Auto-save played YouTube tracks into the library ───────────────────
  // Fires once a YouTube-sourced track finishes playing NATURALLY (this
  // event, unlike skip/prev/next, only fires on real completion; those
  // just replace audio.src instead). Server-side default is on
  // (DOWNLOAD_ENABLED=true); a 403 here just means the operator turned it
  // off, which isn't worth surfacing as an error to the listener.
  const autoSavedVideoIds = new Set();

  function postSaveToLibrary(videoId) {
    const headers = {};
    if (window.PIHUB_API_TOKEN) headers["X-PiHub-Token"] = window.PIHUB_API_TOKEN;
    return fetch(`api/save/${videoId}`, { method: "POST", headers });
  }

  async function maybeAutoSaveToLibrary(track) {
    if (!track || track.source !== "youtube" || !track.videoId) return;
    if (autoSavedVideoIds.has(track.videoId)) return; // don't re-save a replay
    autoSavedVideoIds.add(track.videoId);

    try {
      const res = await postSaveToLibrary(track.videoId);
      if (!res.ok && res.status !== 403) {
        console.warn("Auto-save to library failed:", await res.text());
      }
    } catch (err) {
      console.warn("Auto-save to library failed:", err);
    }
  }

  // Explicit, user-triggered save from a YouTube search result (the ⬇
  // button); unlike maybeAutoSaveToLibrary above, which fires silently once
  // a track finishes playing naturally, this one shows a real progress bar
  // (backed by GET /api/save/{id}/status, which the backend fills in from
  // yt-dlp's own progress_hooks) and turns into a retry button on failure,
  // since the user has to be looking at this one.
  async function saveToLibraryManually(videoId, button) {
    button.disabled = true;
    const row = button.closest("li");
    const progress = document.createElement("progress");
    progress.className = "save-progress";
    progress.max = 100;
    row.appendChild(progress);

    const setLabel = (text, title) => { button.textContent = text; button.title = title; };
    setLabel("…", "Starting download…");

    try {
      const startRes = await postSaveToLibrary(videoId);
      if (!startRes.ok) {
        throw new Error((await startRes.text()) || `HTTP ${startRes.status}`);
      }

      // Polls until the backend reports a terminal state. There's no
      // server push here (SSE/WebSocket) on purpose; a few requests a
      // second for the handful of seconds a save takes isn't worth the
      // extra moving part on a Pi-scale, single-user app.
      for (;;) {
        const statusRes = await fetch(`api/save/${videoId}/status`);
        const state = await statusRes.json();

        if (state.status === "downloading") {
          if (state.percent != null) progress.value = state.percent;
          else progress.removeAttribute("value"); // indeterminate: no total size reported yet
          setLabel(state.percent != null ? `${Math.round(state.percent)}%` : "…", "Downloading…");
        } else if (state.status === "processing") {
          progress.removeAttribute("value");
          setLabel("…", "Converting to MP3…");
        } else if (state.status === "done") {
          progress.remove();
          setLabel("✓", "Saved to library");
          autoSavedVideoIds.add(videoId); // skip a redundant auto-save if played to completion later
          return;
        } else if (state.status === "error") {
          throw new Error(state.error || "Download failed");
        } else {
          // "idle": the backend has no memory of this id at all, which
          // right after a successful start should never happen.
          throw new Error("Lost track of the download");
        }
        await new Promise((resolve) => setTimeout(resolve, 700));
      }
    } catch (err) {
      progress.remove();
      // Left enabled, unlike a plain error message: clicking this again
      // calls this same function again, i.e. IS the retry.
      setLabel("⟳", `Save failed: ${err.message} (click to retry)`);
      button.disabled = false;
    }
  }

  audio.addEventListener("ended", () => {
    maybeAutoSaveToLibrary(queue[queueIndex]);
    playIndex(queueIndex + 1);
  });
  audio.addEventListener("play", () => { document.getElementById("btn-playpause").textContent = "⏸"; });
  audio.addEventListener("pause", () => { document.getElementById("btn-playpause").textContent = "▶"; });

  const seekEl = document.getElementById("np-seek");
  let seeking = false;
  audio.addEventListener("timeupdate", () => {
    if (!audio.duration) return;
    document.getElementById("np-time-current").textContent = formatTime(audio.currentTime);
    document.getElementById("np-time-total").textContent = formatTime(audio.duration);
    if (!seeking) seekEl.value = (audio.currentTime / audio.duration) * 100;
  });
  seekEl.addEventListener("input", () => { seeking = true; });
  seekEl.addEventListener("change", (e) => {
    if (audio.duration) audio.currentTime = (e.target.value / 100) * audio.duration;
    seeking = false;
  });
  document.getElementById("np-volume").addEventListener("input", (e) => {
    audio.volume = e.target.value / 100;
  });
  audio.volume = 0.8;

  // ── Tabs ────────────────────────────────────────────────────────────
  document.querySelectorAll(".tab-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".tab-btn").forEach((b) => b.classList.remove("active"));
      document.querySelectorAll(".tab-panel").forEach((p) => p.classList.remove("active"));
      btn.classList.add("active");
      document.getElementById(`tab-${btn.dataset.tab}`).classList.add("active");
    });
  });

  // ── Library (Navidrome) ────────────────────────────────────────────
  let libraryStack = [];

  // Gates the WHOLE app, not just the Library tab: before a Navidrome login
  // is saved, YouTube search/download, the queue, and playback are all
  // otherwise fully usable and were, previously, actually usable without
  // ever logging in (YouTube doesn't need Navidrome at all). Locked is the
  // default at page load (see index.html: everything but #app-lock starts
  // with the hidden class already on it), so a slow/failed first ping never
  // flashes the real app before locking back down.
  function setAppLocked(locked) {
    document.getElementById("app-lock").classList.toggle("hidden", !locked);
    document.querySelector(".topbar").classList.toggle("hidden", locked);
    document.querySelector("main").classList.toggle("hidden", locked);
    document.querySelector(".player-bar").classList.toggle("hidden", locked);
  }

  async function initLibrary() {
    const creds = Subsonic.load();
    if (!creds) {
      setAppLocked(true);
      return;
    }
    setAppLocked(false);
    try {
      await Subsonic.ping();
      document.getElementById("library-connection-error").classList.add("hidden");
      document.getElementById("library-browser").classList.remove("hidden");
      showArtists();
    } catch (err) {
      document.getElementById("library-browser").classList.add("hidden");
      if (err.authFailed) {
        // The saved password is actually wrong; back to the login gate.
        Subsonic.clear();
        document.getElementById("login-pass").value = "";
        setAppLocked(true);
        alert("Could not log in to Navidrome: " + err.message);
      } else {
        // Looks like Navidrome (or the proxy in front of it) is temporarily
        // unreachable, not a bad password; keep the saved login, keep the
        // rest of the app usable (YouTube/Queue don't need Navidrome), and
        // offer a retry on just the Library tab instead of logging out.
        document.getElementById("library-connection-error-message").textContent =
          "Could not reach Navidrome: " + err.message;
        document.getElementById("library-connection-error").classList.remove("hidden");
      }
    }
  }

  document.getElementById("login-submit").addEventListener("click", async () => {
    const user = document.getElementById("login-user").value.trim();
    const pass = document.getElementById("login-pass").value;
    if (!user || !pass) return;
    Subsonic.save(user, pass);
    await initLibrary();
  });

  document.getElementById("library-retry").addEventListener("click", initLibrary);

  // The one way back to the login gate from the connection-error screen
  // without clearing site data by hand: Subsonic.call()'s authFailed flag
  // only fires for Subsonic error codes 40/41, so a wrong password that
  // comes back some other way (or any other misconfiguration) leaves the
  // saved-but-bad credentials in place forever, with Retry just re-trying
  // the same ones.
  document.getElementById("library-use-different-account").addEventListener("click", () => {
    Subsonic.clear();
    document.getElementById("login-pass").value = "";
    document.getElementById("library-connection-error").classList.add("hidden");
    setAppLocked(true);
  });

  function renderBreadcrumbs() {
    const el = document.getElementById("library-breadcrumbs");
    el.innerHTML = "";
    libraryStack.forEach((crumb, i) => {
      const btn = document.createElement("button");
      btn.textContent = crumb.label;
      btn.addEventListener("click", () => {
        libraryStack = libraryStack.slice(0, i + 1);
        crumb.render();
      });
      el.appendChild(btn);
    });
  }

  function renderLibraryList(rows) {
    const list = document.getElementById("library-list");
    list.innerHTML = "";
    rows.forEach((row) => list.appendChild(row));
  }

  // A ping success at page load doesn't guarantee Navidrome stays up for
  // every click afterwards (it can restart mid-session too) — every browse
  // action below goes through this so a drop shows an in-place message
  // instead of silently doing nothing (an uncaught rejection in an async
  // onClick handler).
  function renderLibraryError(message) {
    const list = document.getElementById("library-list");
    list.innerHTML = "";
    const li = document.createElement("li");
    li.className = "item-sub";
    li.textContent = message;
    list.appendChild(li);
  }

  // Shared by every section that lists actual songs (Songs, Favorites,
  // Recently Added's drill-down, a playlist's contents, an album's
  // contents): star/unstar plus add-to-playlist, identical everywhere a
  // song row shows up. `starred` is a local closure variable, not read back
  // off `song` on every click, since buildRow() snapshots icon/title once
  // at creation; toggling has to update the button directly instead.
  function songRowActions(song, track) {
    let starred = !!song.starred;
    return [
      {
        icon: starred ? "★" : "☆",
        title: starred ? "Remove from favorites" : "Add to favorites",
        className: starred ? "item-star starred" : "item-star",
        onClick: async (btn) => {
          btn.disabled = true;
          try {
            if (starred) await Subsonic.unstar(song.id); else await Subsonic.star(song.id);
            starred = !starred;
            btn.textContent = starred ? "★" : "☆";
            btn.title = starred ? "Remove from favorites" : "Add to favorites";
            btn.classList.toggle("starred", starred);
          } catch (err) {
            alert("Could not update favorite: " + err.message);
          } finally {
            btn.disabled = false;
          }
        },
      },
      { icon: "＋", title: "Add to queue", className: "item-queue", onClick: () => addToQueue(track) },
      { icon: "📋", title: "Add to playlist", className: "item-playlist-add", onClick: () => openPlaylistPicker(song) },
    ];
  }

  // ── Playlist modal ───────────────────────────────────────────────────
  // One shared dialog for both "+ New playlist" (Playlists section) and a
  // song's 📋 button (add to an existing playlist, or create one on the
  // spot); replaces the earlier prompt()-based version of both.
  const playlistModal = {
    el: document.getElementById("playlist-modal"),
    title: document.getElementById("playlist-modal-title"),
    hint: document.getElementById("playlist-modal-hint"),
    list: document.getElementById("playlist-modal-list"),
    nameInput: document.getElementById("playlist-modal-name"),
    song: null, // set only when opened from a song's "add to playlist" button

    open() { this.el.classList.remove("hidden"); },
    close() {
      this.el.classList.add("hidden");
      this.song = null;
      this.list.innerHTML = "";
      this.nameInput.value = "";
      this.hint.classList.add("hidden");
    },
    setHint(text) {
      this.hint.textContent = text;
      this.hint.classList.remove("hidden");
    },
  };

  document.getElementById("playlist-modal-close").addEventListener("click", () => playlistModal.close());

  document.getElementById("playlist-modal-create-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = playlistModal.nameInput.value.trim();
    if (!name) return;
    try {
      const created = await Subsonic.createPlaylist(name);
      if (playlistModal.song) {
        const playlistId = created.playlist && created.playlist.id;
        if (playlistId) await Subsonic.addToPlaylist(playlistId, playlistModal.song.id);
      }
      const wasAddingSong = !!playlistModal.song;
      playlistModal.close();
      // Only refresh the Playlists section if it's the one actually being
      // looked at; creating one from a song's add-to-playlist button
      // (browsing Albums, say) shouldn't yank the user over to it.
      const playlistsBtn = document.querySelector('.library-nav-btn[data-section="playlists"]');
      if (!wasAddingSong && playlistsBtn && playlistsBtn.classList.contains("active")) {
        showPlaylists();
      }
    } catch (err) {
      alert("Could not create playlist: " + err.message);
    }
  });

  function openPlaylistCreateModal() {
    playlistModal.song = null;
    playlistModal.title.textContent = "New playlist";
    playlistModal.list.innerHTML = "";
    playlistModal.open();
  }

  async function openPlaylistPicker(song) {
    playlistModal.song = song;
    playlistModal.title.textContent = `Add "${song.title}" to a playlist`;
    playlistModal.list.innerHTML = "";
    playlistModal.open();
    try {
      const data = await Subsonic.getPlaylists();
      const playlists = (data.playlists && data.playlists.playlist) || [];
      if (!playlists.length) {
        playlistModal.setHint("No playlists yet. Create one below.");
        return;
      }
      playlists.forEach((p) => {
        const li = document.createElement("li");
        li.className = "item-row";
        const meta = document.createElement("div");
        meta.className = "item-meta";
        meta.textContent = p.name;
        li.appendChild(meta);
        li.addEventListener("click", async () => {
          try {
            await Subsonic.addToPlaylist(p.id, song.id);
            playlistModal.close();
          } catch (err) {
            alert("Could not add to playlist: " + err.message);
          }
        });
        playlistModal.list.appendChild(li);
      });
    } catch (err) {
      playlistModal.setHint("Could not load playlists: " + err.message);
    }
  }

  function songRow(s) {
    const track = { title: s.title, artist: s.artist, src: Subsonic.streamUrl(s.id), source: "local" };
    return buildRow({
      icon: "🎵",
      title: s.title,
      sub: s.artist,
      durationText: s.duration ? formatTime(s.duration) : "",
      onClick: () => enqueue(track),
      actions: songRowActions(s, track),
    });
  }

  function selectLibrarySection(name) {
    document.querySelectorAll(".library-nav-btn").forEach((b) => b.classList.toggle("active", b.dataset.section === name));
  }

  async function showSongsSection() {
    selectLibrarySection("songs");
    libraryStack = [{ label: "Songs", render: showSongsSection }];
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getRandomSongs(100);
      const songs = (data.randomSongs && data.randomSongs.song) || [];
      const list = document.getElementById("library-list");
      list.innerHTML = "";
      const hint = document.createElement("li");
      hint.className = "library-section-hint";
      hint.textContent = "A random sample, not your whole library: there is no Subsonic call for a flat, complete song list.";
      list.appendChild(hint);
      songs.forEach((s) => list.appendChild(songRow(s)));
    } catch (err) {
      renderLibraryError("Could not load songs: " + err.message);
    }
  }

  async function showAlbumsSection() {
    selectLibrarySection("albums");
    libraryStack = [{ label: "Albums", render: showAlbumsSection }];
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getAlbumList2("alphabeticalByName", 500);
      const albums = (data.albumList2 && data.albumList2.album) || [];
      renderLibraryList(albums.map((al) => buildRow({
        thumbUrl: al.coverArt ? Subsonic.coverArtUrl(al.coverArt) : null,
        icon: "💿",
        title: al.name,
        sub: al.artist || (al.year ? String(al.year) : ""),
        onClick: () => showAlbumSongs(al.id, al.name),
      })));
    } catch (err) {
      renderLibraryError("Could not load albums: " + err.message);
    }
  }

  async function showArtists() {
    selectLibrarySection("artists");
    libraryStack = [{ label: "Artists", render: showArtists }];
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getArtists();
      const index = (data.artists && data.artists.index) || [];
      const artists = index.flatMap((idx) => idx.artist || []);
      renderLibraryList(artists.map((a) => buildRow({
        thumbUrl: a.coverArt ? Subsonic.coverArtUrl(a.coverArt) : null,
        icon: "🎤",
        title: a.name,
        sub: `${a.albumCount || 0} album${a.albumCount === 1 ? "" : "s"}`,
        onClick: () => showArtistAlbums(a.id, a.name),
      })));
    } catch (err) {
      renderLibraryError("Could not load artists: " + err.message);
    }
  }

  async function showArtistAlbums(artistId, artistName) {
    libraryStack.push({ label: artistName, render: () => showArtistAlbums(artistId, artistName) });
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getArtist(artistId);
      const albums = (data.artist && data.artist.album) || [];
      renderLibraryList(albums.map((al) => buildRow({
        thumbUrl: al.coverArt ? Subsonic.coverArtUrl(al.coverArt) : null,
        icon: "💿",
        title: al.name,
        sub: al.year ? String(al.year) : "",
        onClick: () => showAlbumSongs(al.id, al.name),
      })));
    } catch (err) {
      renderLibraryError("Could not load albums: " + err.message);
    }
  }

  async function showAlbumSongs(albumId, albumName) {
    libraryStack.push({ label: albumName, render: () => showAlbumSongs(albumId, albumName) });
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getAlbum(albumId);
      const songs = (data.album && data.album.song) || [];
      renderLibraryList(songs.map(songRow));
    } catch (err) {
      renderLibraryError("Could not load tracks: " + err.message);
    }
  }

  async function showFavorites() {
    selectLibrarySection("favorites");
    libraryStack = [{ label: "Favorites", render: showFavorites }];
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getStarred2();
      const songs = (data.starred2 && data.starred2.song) || [];
      if (!songs.length) {
        renderLibraryError("No favorites yet. Star a song anywhere in the library to add one.");
        return;
      }
      renderLibraryList(songs.map(songRow));
    } catch (err) {
      renderLibraryError("Could not load favorites: " + err.message);
    }
  }

  async function showRecentlyAdded() {
    selectLibrarySection("recent");
    libraryStack = [{ label: "Recently Added", render: showRecentlyAdded }];
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getAlbumList2("newest", 50);
      const albums = (data.albumList2 && data.albumList2.album) || [];
      renderLibraryList(albums.map((al) => buildRow({
        thumbUrl: al.coverArt ? Subsonic.coverArtUrl(al.coverArt) : null,
        icon: "💿",
        title: al.name,
        sub: al.artist || (al.year ? String(al.year) : ""),
        onClick: () => showAlbumSongs(al.id, al.name),
      })));
    } catch (err) {
      renderLibraryError("Could not load recently added albums: " + err.message);
    }
  }

  async function showPlaylists() {
    selectLibrarySection("playlists");
    libraryStack = [{ label: "Playlists", render: showPlaylists }];
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getPlaylists();
      const playlists = (data.playlists && data.playlists.playlist) || [];
      const list = document.getElementById("library-list");
      list.innerHTML = "";

      const createRow = document.createElement("li");
      createRow.className = "library-action-row";
      const createBtn = document.createElement("button");
      createBtn.textContent = "+ New playlist";
      createBtn.addEventListener("click", () => openPlaylistCreateModal());
      createRow.appendChild(createBtn);
      list.appendChild(createRow);

      if (!playlists.length) {
        const hint = document.createElement("li");
        hint.className = "library-section-hint";
        hint.textContent = "No playlists yet.";
        list.appendChild(hint);
        return;
      }
      playlists.forEach((p) => list.appendChild(buildRow({
        icon: "📃",
        title: p.name,
        sub: `${p.songCount || 0} song${p.songCount === 1 ? "" : "s"}`,
        onClick: () => showPlaylistDetail(p.id, p.name),
      })));
    } catch (err) {
      renderLibraryError("Could not load playlists: " + err.message);
    }
  }

  async function showPlaylistDetail(playlistId, name) {
    libraryStack.push({ label: name, render: () => showPlaylistDetail(playlistId, name) });
    renderBreadcrumbs();
    try {
      const data = await Subsonic.getPlaylist(playlistId);
      const songs = (data.playlist && data.playlist.entry) || [];
      if (!songs.length) {
        renderLibraryError("This playlist is empty. Use a song's 📋 button anywhere in the library to add one.");
        return;
      }
      renderLibraryList(songs.map(songRow));
    } catch (err) {
      renderLibraryError("Could not load playlist: " + err.message);
    }
  }

  document.querySelectorAll(".library-nav-btn").forEach((btn) => {
    const sections = {
      songs: showSongsSection, albums: showAlbumsSection, artists: showArtists,
      favorites: showFavorites, recent: showRecentlyAdded, playlists: showPlaylists,
    };
    btn.addEventListener("click", () => sections[btn.dataset.section]());
  });

  // ── YouTube search ──────────────────────────────────────────────────
  document.getElementById("yt-search-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const q = document.getElementById("yt-search-input").value.trim();
    if (!q) return;
    const list = document.getElementById("yt-results");
    list.innerHTML = "";
    const loading = document.createElement("li");
    loading.className = "item-sub";
    loading.textContent = "Searching…";
    list.appendChild(loading);

    try {
      const res = await fetch(`api/search?q=${encodeURIComponent(q)}`);
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      list.innerHTML = "";
      if (!data.results.length) {
        const empty = document.createElement("li");
        empty.className = "item-sub";
        empty.textContent = "No results.";
        list.appendChild(empty);
        return;
      }
      data.results.forEach((r) => {
        const track = { title: r.title, artist: r.artist, src: `api/stream/${r.id}`, source: "youtube", videoId: r.id };
        list.appendChild(buildRow({
          thumbUrl: r.thumbnail,
          icon: "▶",
          title: r.title,
          sub: r.artist,
          durationText: r.duration ? formatTime(r.duration) : "",
          onClick: () => enqueue(track),
          actions: [
            { icon: "＋", title: "Add to queue", className: "item-queue", onClick: () => addToQueue(track) },
            { icon: "⬇", title: "Save to library", className: "item-save", onClick: (btn) => saveToLibraryManually(r.id, btn) },
          ],
        }));
      });
    } catch (err) {
      list.innerHTML = "";
      const errEl = document.createElement("li");
      errEl.className = "item-sub";
      errEl.textContent = "Search failed: " + err.message;
      list.appendChild(errEl);
    }
  });

  // ── Discover (not yet implemented) ─────────────────────────────────
  // Scaffolding only, per README.md's Discover section: the UI and the
  // shape of the calls it will make, wired to empty backend stubs
  // (POST /api/discover/analyze, GET /api/discover/status,
  // GET /api/discover/similar/{id} in app/main.py), none of which do
  // anything yet. Deliberately not started automatically or on a
  // schedule: both real algorithms behind this (raw audio analysis for
  // tempo/key/mood, then Annoy for similarity grouping) are CPU-heavy
  // enough on a Pi that starting them needs to stay an explicit, visible
  // choice, not a side effect of opening this tab.
  //
  // Left as empty functions rather than removed entirely, so the actual
  // implementation later has the UI hookup already in place and only
  // needs to fill these in.
  async function discoverStartAnalysis() {
    // TODO: POST /api/discover/analyze, then poll discoverPollStatus().
  }

  async function discoverPollStatus() {
    // TODO: GET /api/discover/status, update #discover-progress.
  }

  function discoverRenderResults(_similarTracks) {
    // TODO: render #discover-results once /api/discover/similar/{id}
    // returns something real.
  }

  // ── Init ────────────────────────────────────────────────────────────
  renderQueue();
  renderNowPlaying();
  initLibrary();
})();
