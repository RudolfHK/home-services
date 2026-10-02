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
    getSong(id) { return this.call("getSong", { id }); },
    getRandomSongs(size) { return this.call("getRandomSongs", { size }); },
    // extra: type-specific params, e.g. {fromYear, toYear} for type "byYear".
    getAlbumList2(type, size, offset, extra) {
      return this.call("getAlbumList2", { type, size, offset: offset || 0, ...(extra || {}) });
    },
    getStarred2() { return this.call("getStarred2"); },
    // submission=true is a real play (increments Navidrome's own playCount,
    // which is where "Most Played" and every song's play count come from;
    // nothing PiTune tracks itself, so it survives PiTune being restarted
    // same as anything else already living in Navidrome's own database).
    // submission=false is just "now playing", which is also what makes a
    // PiTune-initiated play show up in PiMonitor's "who's listening" tile.
    scrobble(id, submission) { return this.call("scrobble", { id, submission }); },
    search3(query, { songCount, songOffset, artistCount, albumCount } = {}) {
      return this.call("search3", {
        query,
        songCount: songCount != null ? songCount : 100, songOffset: songOffset || 0,
        artistCount: artistCount != null ? artistCount : 0,
        albumCount: albumCount != null ? albumCount : 0,
      });
    },
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

  function formatViewCount(n) {
    if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
    if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
    if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
    return String(n);
  }

  // "3 weeks ago", the way YouTube's own results label uploads, from
  // main.py's uploadedAt (epoch seconds). That value is itself derived
  // from YouTube's own relative label (see main.py's _FLAT_OPTS), so it's
  // never meaningfully more precise than this.
  const AGE_UNITS = [["year", 365 * 86400], ["month", 30 * 86400], ["week", 7 * 86400], ["day", 86400], ["hour", 3600], ["minute", 60]];
  function formatAge(epochSec) {
    const age = Date.now() / 1000 - epochSec;
    if (!isFinite(age)) return "";
    for (const [unit, secs] of AGE_UNITS) {
      const n = Math.floor(age / secs);
      if (n >= 1) return `${n} ${unit}${n === 1 ? "" : "s"} ago`;
    }
    return "just now";
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

  // Shared by renderNowPlaying and playIndex's own immediate "Loading…"
  // state (playIndex already knows `track` synchronously and doesn't need to
  // wait for the "playing" event to show its thumbnail too).
  function setNowPlayingThumb(track) {
    const thumb = document.getElementById("np-thumb");
    if (track && track.thumbUrl) {
      thumb.src = track.thumbUrl;
      thumb.classList.remove("hidden");
    } else {
      thumb.removeAttribute("src");
      thumb.classList.add("hidden");
    }
  }

  // "youtube:<videoId>" / "local:<songId>": what ytResultRows and
  // libraryResultRows are keyed by, so either list can hold either kind of
  // row (Most Played, in the Library tab, shows YouTube tracks too).
  function trackKey(track) {
    if (!track) return null;
    return track.source === "youtube" ? `youtube:${track.videoId}` : `local:${track.id}`;
  }

  // Mirrors the currently-playing track onto whichever list rows can show
  // it: the Queue (rebuilt on every change anyway, handled in renderQueue
  // itself via the "playing" class) and the YouTube tab's search/channel
  // results, which stay mounted across a play (searching doesn't rebuild the
  // list), so their highlight has to be pushed in from here instead of
  // baked in at render time.
  function updateNowPlayingHighlights() {
    const playingKey = trackKey(queue[queueIndex]);
    [ytResultRows, libraryResultRows].forEach((rows) => {
      rows.forEach((row, key) => row.classList.toggle("playing", key === playingKey));
    });
  }

  function renderNowPlaying() {
    const track = queue[queueIndex];
    document.getElementById("np-title").textContent = track ? track.title : "Nothing playing";
    document.getElementById("np-artist").textContent = track ? (track.artist || "") : "";
    setNowPlayingThumb(track);
    updateNowPlayingHighlights();
  }

  function playIndex(i) {
    // Moving away from whatever was current means it's been played through
    // or skipped past; gone from the queue entirely now, not just left
    // sitting there deselected. Anything before the removed slot keeps its
    // position; anything after (including the target, if it was ahead)
    // shifts down by one to follow the removal.
    if (queueIndex >= 0 && queueIndex < queue.length) {
      queue.splice(queueIndex, 1);
      if (i > queueIndex) i--;
    }
    if (i < 0 || i >= queue.length) {
      queueIndex = -1;
      audio.pause();
      audio.removeAttribute("src");
      renderNowPlaying();
      renderQueue();
      return;
    }
    queueIndex = i;
    const track = queue[i];
    // /api/stream (YouTube) and even a local Navidrome file over a slow
    // link both take a visible moment before audio.play() actually
    // produces sound; say so, rather than leaving the old title on screen
    // looking like nothing happened. Cleared by the "playing" listener
    // below once real playback starts.
    document.getElementById("np-title").textContent = "Loading…";
    document.getElementById("np-artist").textContent = track.artist || "";
    document.querySelector(".now-playing").classList.add("loading");
    setNowPlayingThumb(track); // known synchronously; no need to wait for "playing"
    updateNowPlayingHighlights();
    audio.src = track.src;
    audio.play().catch((err) => console.warn("Playback failed:", err));
    if (track.source === "local" && track.id) {
      // "Now playing" (not yet a counted play); also what makes this show
      // up in PiMonitor's "who's listening" tile, same as any other
      // Subsonic client's playback would.
      Subsonic.scrobble(track.id, false).catch((err) => console.warn("Scrobble (now playing) failed:", err));
    }
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
    if (!audio.src) {
      // Nothing loaded yet; most often songs were queued via "Add to
      // queue" (which deliberately doesn't start playback) and Play is the
      // first thing pressed. Start from the front of the queue instead of
      // silently doing nothing.
      if (queue.length) playIndex(0);
      return;
    }
    if (audio.paused) audio.play(); else audio.pause();
  });
  document.getElementById("btn-next").addEventListener("click", () => playIndex(queueIndex + 1));
  document.getElementById("btn-prev").addEventListener("click", () => {
    // Nothing queued before the current track (which is the usual case,
    // since playIndex removes each track once it's been played through):
    // restart it instead. playIndex(-1) would remove the current track
    // from the queue too, and then stop playback with nothing left loaded.
    if (audio.currentTime > 3 || queueIndex <= 0) { audio.currentTime = 0; return; }
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

  // ── PiTune's own play counter (separate from Navidrome's scrobble) ─────
  // Navidrome only ever knows about local library songs; a YouTube track
  // earns no play count anywhere until it's saved into the library, and
  // even saved ones only showed up in "Most Played" via a random sample
  // (Subsonic has no real "most played" endpoint). Recording a play here,
  // for both sources, on the same "natural finish only" condition as
  // Navidrome's own scrobble(id, true) below, is what makes /api/playcount/
  // top an exact ranking across local AND YouTube tracks. See showMostPlayed
  // and main.py's module docstring.
  function recordPlay(track) {
    const source = track && track.source === "youtube" ? "youtube" : track && track.source === "local" ? "local" : null;
    const id = source === "youtube" ? track.videoId : source === "local" ? track.id : null;
    if (!source || !id) return;
    const headers = { "Content-Type": "application/json" };
    if (window.PIHUB_API_TOKEN) headers["X-PiHub-Token"] = window.PIHUB_API_TOKEN;
    const body = source === "youtube" ? { title: track.title, artist: track.artist, thumbnail: track.thumbUrl } : {};
    fetch(`api/playcount/${source}/${id}`, { method: "POST", headers, body: JSON.stringify(body) })
      .catch((err) => console.warn("Recording play count failed:", err));
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
    const finished = queue[queueIndex];
    maybeAutoSaveToLibrary(finished);
    // submission=true only on a real, natural finish (this event fires for
    // that and nothing else, not skip/prev/next, which just replace
    // audio.src instead); a track abandoned partway through isn't "a
    // play" the way Navidrome's own playCount (or PiTune's own, below)
    // means it.
    if (finished && finished.source === "local" && finished.id) {
      Subsonic.scrobble(finished.id, true).catch((err) => console.warn("Scrobble failed:", err));
    }
    recordPlay(finished); // PiTune's own counter, local AND YouTube alike
    playIndex(queueIndex + 1);
  });
  audio.addEventListener("play", () => { document.getElementById("btn-playpause").textContent = "⏸"; });
  audio.addEventListener("pause", () => { document.getElementById("btn-playpause").textContent = "▶"; });
  audio.addEventListener("playing", () => {
    document.querySelector(".now-playing").classList.remove("loading");
    renderNowPlaying();
  });
  audio.addEventListener("error", () => {
    if (!audio.src) return; // removeAttribute("src") itself fires a spurious error event
    document.querySelector(".now-playing").classList.remove("loading");
    document.getElementById("np-title").textContent = "Playback error";
  });

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
  const volumeSlider = document.getElementById("np-volume");
  const muteBtn = document.getElementById("np-mute");
  // Muting sets audio.muted rather than volume = 0: iOS Safari ignores
  // writes to HTMLMediaElement.volume entirely (volume there is the
  // hardware buttons' job), so a volume-based mute silently did nothing on
  // an iPhone, while `muted` is honored everywhere. It also leaves the
  // volume itself untouched, so unmuting restores it without having to
  // remember it. The one exception is a slider dragged all the way to 0:
  // unmuting from there has nothing to restore, so it falls back to the
  // last audible level instead.
  let lastAudibleVolume = 0.8;

  // slider: false while the slider itself is being dragged, so it stays
  // under the user's finger (on iOS, where the volume write is ignored,
  // syncing it would snap it straight back to 100 mid-drag).
  function syncVolumeUi({ slider = true } = {}) {
    const silent = audio.muted || audio.volume === 0;
    muteBtn.textContent = silent ? "🔇" : audio.volume < 0.5 ? "🔉" : "🔊";
    muteBtn.title = silent ? "Unmute" : "Mute";
    if (slider) volumeSlider.value = silent ? 0 : Math.round(audio.volume * 100);
  }

  volumeSlider.addEventListener("input", (e) => {
    const volume = e.target.value / 100;
    audio.volume = volume;
    audio.muted = volume === 0; // dragging back up from 0 unmutes too
    if (volume > 0) lastAudibleVolume = volume;
    syncVolumeUi({ slider: false });
  });
  muteBtn.addEventListener("click", () => {
    if (audio.muted || audio.volume === 0) {
      if (audio.volume === 0) audio.volume = lastAudibleVolume;
      audio.muted = false;
    } else {
      audio.muted = true;
    }
    syncVolumeUi();
  });
  // Also covers changes made outside this UI (e.g. the OS/browser's own
  // media controls); fires asynchronously, hence the direct calls above too.
  audio.addEventListener("volumechange", () => syncVolumeUi({ slider: document.activeElement !== volumeSlider }));
  audio.volume = 0.8;
  syncVolumeUi();

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
      populateLibraryFilterArtists();
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
        // Up to but NOT including this crumb: a drill-down's render()
        // pushes its own crumb back on (a top-level section's resets the
        // whole stack), so keeping it here too would show it twice.
        libraryStack = libraryStack.slice(0, i);
        crumb.render();
      });
      el.appendChild(btn);
    });
  }

  // Bumped by every library view as it starts (sections, drill-downs,
  // search, all through startLibraryView below). An async load compares
  // the value it started with before touching #library-list, so a slow
  // response for a view the user has already left (another section, or the
  // same one re-run by a filter change) can't overwrite or append into
  // whatever replaced it.
  let libraryViewSeq = 0;

  // filterMode: which of the filter bar's controls apply to this view.
  // "songs": all of them. "albums": artist + year (duration is per-song).
  // "none": hidden, for views that list neither (Artists, Playlists), and
  // for the ones that deliberately show a complete, unfiltered set (an
  // album's or artist's full contents, Most Played's ranking).
  function startLibraryView(filterMode) {
    libraryViewSeq++;
    renderBreadcrumbs();
    // Only the Songs section shows this, and it un-hides it itself; any
    // other view (Playlists writes #library-list directly) would otherwise
    // inherit a still-visible one from Songs.
    document.getElementById("library-load-more").classList.add("hidden");
    document.getElementById("library-filters").classList.toggle("hidden", filterMode === "none");
    document.getElementById("library-filter-duration-label").classList.toggle("hidden", filterMode === "albums");
    return libraryViewSeq;
  }

  // Re-runs whatever the breadcrumbs currently end on (a section, a
  // drill-down like a playlist's contents, or a search), e.g. after a
  // filter change; see renderBreadcrumbs for why its crumb is popped first.
  function rerenderCurrentLibraryView() {
    const current = libraryStack[libraryStack.length - 1];
    if (!current) return;
    libraryStack = libraryStack.slice(0, -1);
    current.render();
  }

  // Callers build `rows` via .map(songRow) (or buildRow directly, for
  // Albums/Artists), which is what actually populates libraryResultRows;
  // by the time rows reach here that's already done, so resetting the map
  // is the CALLER's job (before building rows), not this function's; see
  // each section's own "fresh view" reset.
  function renderLibraryList(rows) {
    const list = document.getElementById("library-list");
    list.innerHTML = "";
    rows.forEach((row) => list.appendChild(row));
    // Only the Songs section (showSongsSection) manages this itself;
    // every other section renders its one complete result set through
    // here, so hiding it by default means Songs is the only place it's
    // ever visible.
    document.getElementById("library-load-more").classList.add("hidden");
    updateNowPlayingHighlights(); // in case whatever's already playing is in this list
  }

  // A ping success at page load doesn't guarantee Navidrome stays up for
  // every click afterwards (it can restart mid-session too) — every browse
  // action below goes through this so a drop shows an in-place message
  // instead of silently doing nothing (an uncaught rejection in an async
  // onClick handler).
  function renderLibraryError(message) {
    const list = document.getElementById("library-list");
    list.innerHTML = "";
    libraryResultRows = new Map();
    document.getElementById("library-load-more").classList.add("hidden");
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

  // Shared by songRow below and playTracks (playlist sequence/shuffle
  // playback, see showPlaylistDetail): id travels with the track
  // specifically so playIndex()/the "ended" handler can scrobble plays back
  // to Navidrome and record a PiTune play count; see their own comments.
  function songToTrack(s) {
    return {
      title: s.title, artist: s.artist, src: Subsonic.streamUrl(s.id), source: "local", id: s.id,
      // Every Child (song) element carries its own coverArt id, usable
      // directly with getCoverArt; no separate album lookup needed.
      thumbUrl: s.coverArt ? Subsonic.coverArtUrl(s.coverArt) : null,
    };
  }

  // Replaces the queue outright with `tracks` (in order, or shuffled) and
  // starts playing from the front, distinct from enqueue()/addToQueue(),
  // which only ever add ONE track, since "play this whole playlist" means
  // starting fresh, not appending after whatever was already queued.
  function playTracks(tracks, { shuffle = false } = {}) {
    const ordered = tracks.slice();
    if (shuffle) {
      // Fisher-Yates: uniform, in-place, O(n).
      for (let i = ordered.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [ordered[i], ordered[j]] = [ordered[j], ordered[i]];
      }
    }
    queue = ordered;
    queueIndex = -1;
    renderQueue();
    playIndex(0);
  }

  // trackKey -> <li>, mirroring ytResultRows in the YouTube tab section below:
  // only ever holds whatever's CURRENTLY rendered in #library-list, so
  // updateNowPlayingHighlights (see the player section above) never touches
  // a stale/removed row. Cleared wherever the list is actually wiped
  // (renderLibraryList, renderLibraryError, and the two places that bypass
  // those to manage #library-list directly: showSongsSection's fresh start
  // and the search form's "Searching…" placeholder), NOT on every
  // loadMoreSongs() batch, since those APPEND to what's already showing.
  let libraryResultRows = new Map();

  function songRow(s) {
    const track = songToTrack(s);
    const plays = s.playCount ? ` · ${s.playCount} play${s.playCount === 1 ? "" : "s"}` : "";
    const row = buildRow({
      icon: "🎵",
      title: s.title,
      sub: (s.artist || "") + plays,
      durationText: s.duration ? formatTime(s.duration) : "",
      onClick: () => enqueue(track),
      actions: songRowActions(s, track),
    });
    libraryResultRows.set(trackKey(track), row);
    return row;
  }

  function selectLibrarySection(name) {
    document.querySelectorAll(".library-nav-btn").forEach((b) => b.classList.toggle("active", b.dataset.section === name));
  }

  // ── Library filters (artist / duration / year) ─────────────────────────
  // Applied client-side to every view that already has full song metadata
  // in hand (Songs, Favorites, Recently Added, Playlist detail, Search):
  // Subsonic has no server-side equivalent of this combination, but every
  // field involved (artist, duration, year) already comes back on every
  // Child (song) element for free, so filtering after the fact costs
  // nothing extra network-wise. Albums gets artist + year (see
  // applyLibraryAlbumFilters). Where a filter CAN narrow what gets fetched
  // in the first place, Songs and Albums do that rather than paging
  // through the whole library for the few matches (songsForArtist,
  // albumListQueryForFilters). Deliberately NOT applied to Most Played,
  // which is a ranking (see showMostPlayed); startLibraryView hides the
  // bar wherever it doesn't apply.
  const DURATION_BUCKETS = { short: [0, 240], medium: [240, 1200], long: [1200, Infinity] };

  function currentLibraryFilters() {
    const artistSelect = document.getElementById("library-filter-artist");
    const yearFrom = document.getElementById("library-filter-year-from").value;
    const yearTo = document.getElementById("library-filter-year-to").value;
    return {
      // {id, name}: the id matches Navidrome's own artist links exactly;
      // the name is the fallback for fields that carry only a string.
      artist: artistSelect.value ? { id: artistSelect.value, name: artistSelect.selectedOptions[0].textContent } : null,
      duration: document.getElementById("library-filter-duration").value,
      yearFrom: yearFrom ? Number(yearFrom) : null,
      yearTo: yearTo ? Number(yearTo) : null,
    };
  }

  function libraryFiltersActive() {
    const f = currentLibraryFilters();
    return !!f.artist || f.duration !== "any" || f.yearFrom != null || f.yearTo != null;
  }

  // The artist dropdown lists ALBUM artists (getArtists), but a song's own
  // `artist` string is its track artist, often "Alpha feat. Beta", or
  // someone else entirely on a compilation. Comparing only that string
  // missed every featured appearance and every track on a Various Artists
  // album. OpenSubsonic servers (Navidrome included) also list each song's
  // individual artists and album artists by id, which catches both; the
  // plain-string comparisons cover servers that don't.
  function songMatchesArtist(s, artist) {
    const ids = [s.artistId, ...(s.artists || []).map((a) => a.id), ...(s.albumArtists || []).map((a) => a.id)];
    return ids.includes(artist.id) || s.artist === artist.name || s.displayAlbumArtist === artist.name;
  }

  function albumMatchesArtist(al, artist) {
    const ids = [al.artistId, ...(al.artists || []).map((a) => a.id)];
    return ids.includes(artist.id) || al.artist === artist.name;
  }

  function yearInRange(year, yearFrom, yearTo) {
    if (yearFrom != null && (!year || year < yearFrom)) return false;
    if (yearTo != null && (!year || year > yearTo)) return false;
    return true;
  }

  function applyLibraryFilters(songs) {
    if (!libraryFiltersActive()) return songs;
    const { artist, duration, yearFrom, yearTo } = currentLibraryFilters();
    return songs.filter((s) => {
      if (artist && !songMatchesArtist(s, artist)) return false;
      if (duration !== "any") {
        const [lo, hi] = DURATION_BUCKETS[duration];
        if (s.duration == null || s.duration < lo || s.duration >= hi) return false;
      }
      return yearInRange(s.year, yearFrom, yearTo);
    });
  }

  // Duration buckets describe single songs, so they don't apply to whole
  // albums; startLibraryView("albums") hides that control accordingly.
  function applyLibraryAlbumFilters(albums) {
    const { artist, yearFrom, yearTo } = currentLibraryFilters();
    return albums.filter((al) => (!artist || albumMatchesArtist(al, artist)) && yearInRange(al.year, yearFrom, yearTo));
  }

  // getAlbumList2 arguments that let Navidrome itself narrow albums to the
  // year filter's range ("byYear" requires both ends, hence the open-ended
  // defaults), instead of paging alphabetically through all of them.
  function albumListQueryForFilters({ yearFrom, yearTo }) {
    if (yearFrom == null && yearTo == null) return { type: "alphabeticalByName", extra: {} };
    return { type: "byYear", extra: { fromYear: yearFrom != null ? yearFrom : 1, toYear: yearTo != null ? yearTo : 9999 } };
  }

  // Populated after login (see initLibrary); getArtists() is already the
  // whole-library artist index. Rebuilt rather than appended to, since
  // initLibrary runs again on every Retry and re-login.
  async function populateLibraryFilterArtists() {
    const select = document.getElementById("library-filter-artist");
    try {
      const data = await Subsonic.getArtists();
      const index = (data.artists && data.artists.index) || [];
      const byId = new Map(index.flatMap((idx) => idx.artist || []).map((a) => [a.id, a]));
      const selected = select.value;
      while (select.options.length > 1) select.remove(1); // keep "All artists"
      [...byId.values()].sort((a, b) => a.name.localeCompare(b.name)).forEach((a) => {
        const opt = document.createElement("option");
        opt.value = a.id;
        opt.textContent = a.name;
        select.appendChild(opt);
      });
      select.value = byId.has(selected) ? selected : "";
    } catch (err) {
      console.warn("Could not load artists for the library filter bar:", err);
    }
  }

  // Changing a filter re-runs whatever is currently shown from scratch,
  // the same "start over, don't try to patch what's already rendered"
  // approach the YouTube tab's own filters use. The current VIEW, not the
  // sidebar's active section: inside a playlist, re-running "Playlists"
  // threw away the playlist being filtered and went back to the list.
  ["library-filter-artist", "library-filter-duration", "library-filter-year-from", "library-filter-year-to"].forEach((id) => {
    document.getElementById(id).addEventListener("change", () => rerenderCurrentLibraryView());
  });

  // Subsonic has no endpoint for "list every song, paginated"; only
  // albums support offset-based paging (getAlbumList2). This section
  // fakes the song-level version of that by paging through ALBUMS and
  // flattening each page's songs, a handful of albums at a time rather
  // than fetching genuinely all of them up front (which would mean one
  // enormous request and a long wait before anything shows up on a big
  // library). There's no total or page count to show since Subsonic
  // doesn't expose a song count either, only whichever real library data
  // has actually loaded.
  //
  // Filtering each five-album batch after the fact meant that, on a real
  // library, most batches added nothing and the list sat empty until "Load
  // more" had been pressed enough times to stumble onto a match. So: an
  // artist filter fetches that artist's songs directly (songsForArtist, no
  // paging at all); a year filter pages only albums from those years
  // (albumListQueryForFilters); and one load keeps fetching batches until
  // it has SONGS_SECTION_MIN_NEW_ROWS new matches, the albums run out, or
  // SONGS_SECTION_MAX_BATCHES batches have gone by, so an unusually narrow
  // duration filter still hands control back rather than silently walking
  // the whole library in one go.
  const SONGS_SECTION_ALBUM_BATCH = 5;
  const SONGS_SECTION_MIN_NEW_ROWS = 20;
  const SONGS_SECTION_MAX_BATCHES = 10;
  let songsSectionPaging = null; // {seq, type, extra, offset, shown, hint}

  async function loadMoreSongs() {
    const paging = songsSectionPaging;
    if (!paging || paging.seq !== libraryViewSeq) return;
    const btn = document.getElementById("library-load-more");
    const list = document.getElementById("library-list");
    btn.disabled = true;
    btn.textContent = "Loading…";
    let added = 0;
    let exhausted = false;
    try {
      for (let batch = 0; batch < SONGS_SECTION_MAX_BATCHES && added < SONGS_SECTION_MIN_NEW_ROWS && !exhausted; batch++) {
        const data = await Subsonic.getAlbumList2(paging.type, SONGS_SECTION_ALBUM_BATCH, paging.offset, paging.extra);
        if (paging.seq !== libraryViewSeq) return; // the user has moved on; see libraryViewSeq
        const albums = (data.albumList2 && data.albumList2.album) || [];
        paging.offset += albums.length;
        exhausted = albums.length < SONGS_SECTION_ALBUM_BATCH;
        // allSettled, not all: one bad album (removed mid-scan, say)
        // must not abort every other album's songs along with it.
        const albumDetails = (await Promise.allSettled(albums.map((al) => Subsonic.getAlbum(al.id))))
          .filter((r) => r.status === "fulfilled").map((r) => r.value);
        if (paging.seq !== libraryViewSeq) return;
        albumDetails.forEach((detail) => {
          applyLibraryFilters((detail.album && detail.album.song) || []).forEach((s) => {
            list.appendChild(songRow(s));
            added++;
          });
        });
      }
      paging.shown += added;
      updateNowPlayingHighlights(); // in case whatever's already playing is in this batch
      if (!paging.shown && exhausted) {
        renderLibraryError(libraryFiltersActive() ? "No songs match these filters." : "No songs in the library yet.");
        return;
      }
      if (!paging.shown) {
        paging.hint.textContent = `No matches in the first ${paging.offset} albums yet. Load more to keep looking.`;
      }
      if (exhausted) {
        btn.textContent = "No more songs"; // stays disabled: this was the last page
      } else {
        btn.textContent = "Load more";
        btn.disabled = false;
      }
    } catch (err) {
      if (paging.seq !== libraryViewSeq) return;
      btn.textContent = "Load more (failed, tap to retry)";
      btn.disabled = false;
    }
  }

  // An artist filter's songs, fetched directly: the artist's own albums
  // (getArtist), plus a search on their name to pick up featured
  // appearances on other artists' albums and compilations, which getArtist
  // doesn't list. applyLibraryFilters then keeps exactly what
  // songMatchesArtist accepts, along with the other filters.
  async function songsForArtist(artist) {
    const [artistData, searchData] = await Promise.all([
      Subsonic.getArtist(artist.id),
      // Extra coverage only: its failing isn't worth failing the rest over.
      Subsonic.search3(artist.name, { songCount: 500 }).catch(() => null),
    ]);
    const albums = (artistData.artist && artistData.artist.album) || [];
    const albumDetails = (await Promise.allSettled(albums.map((al) => Subsonic.getAlbum(al.id))))
      .filter((r) => r.status === "fulfilled").map((r) => r.value);
    const songs = new Map();
    albumDetails.forEach((detail) => ((detail.album && detail.album.song) || []).forEach((s) => songs.set(s.id, s)));
    ((searchData && searchData.searchResult3 && searchData.searchResult3.song) || [])
      .forEach((s) => { if (!songs.has(s.id)) songs.set(s.id, s); });
    return applyLibraryFilters([...songs.values()]);
  }

  async function showSongsSection() {
    selectLibrarySection("songs");
    libraryStack = [{ label: "Songs", render: showSongsSection }];
    const seq = startLibraryView("songs");
    songsSectionPaging = null;
    libraryResultRows = new Map();
    const list = document.getElementById("library-list");
    list.innerHTML = "";
    const btn = document.getElementById("library-load-more");
    btn.classList.add("hidden");
    const filters = currentLibraryFilters();

    if (filters.artist) {
      const loading = document.createElement("li");
      loading.className = "item-sub";
      loading.textContent = "Loading…";
      list.appendChild(loading);
      try {
        const songs = await songsForArtist(filters.artist);
        if (seq !== libraryViewSeq) return;
        if (!songs.length) {
          renderLibraryError(`No songs by ${filters.artist.name} match these filters.`);
          return;
        }
        renderLibraryList(songs.map(songRow));
      } catch (err) {
        if (seq !== libraryViewSeq) return;
        renderLibraryError("Could not load songs: " + err.message);
      }
      return;
    }

    const { type, extra } = albumListQueryForFilters(filters);
    const hint = document.createElement("li");
    hint.className = "library-section-hint";
    hint.textContent = type === "byYear"
      ? "Albums from the selected years, a few at a time; Load more for further albums."
      : "Loaded album by album, alphabetically. Subsonic has no flat \"every song\" call to page through directly; Load more for further albums.";
    list.appendChild(hint);
    songsSectionPaging = { seq, type, extra, offset: 0, shown: 0, hint };
    btn.classList.remove("hidden");
    btn.onclick = loadMoreSongs; // assignment, not addEventListener: revisiting this section must not stack a second handler
    await loadMoreSongs();
  }

  async function showAlbumsSection() {
    selectLibrarySection("albums");
    libraryStack = [{ label: "Albums", render: showAlbumsSection }];
    const seq = startLibraryView("albums");
    const filters = currentLibraryFilters();
    try {
      // Fetch only what the filters allow where Navidrome can narrow it
      // itself: one artist's albums, or one year range; either way,
      // applyLibraryAlbumFilters still applies whichever wasn't used to fetch.
      let fetched;
      if (filters.artist) {
        const data = await Subsonic.getArtist(filters.artist.id);
        fetched = (data.artist && data.artist.album) || [];
      } else {
        const { type, extra } = albumListQueryForFilters(filters);
        const data = await Subsonic.getAlbumList2(type, 500, 0, extra);
        fetched = (data.albumList2 && data.albumList2.album) || [];
      }
      if (seq !== libraryViewSeq) return;
      const albums = applyLibraryAlbumFilters(fetched);
      if (!albums.length) {
        renderLibraryError(libraryFiltersActive() ? "No albums match these filters." : "No albums in the library yet.");
        return;
      }
      renderLibraryList(albums.map((al) => buildRow({
        thumbUrl: al.coverArt ? Subsonic.coverArtUrl(al.coverArt) : null,
        icon: "💿",
        title: al.name,
        sub: al.artist || (al.year ? String(al.year) : ""),
        onClick: () => showAlbumSongs(al.id, al.name),
      })));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load albums: " + err.message);
    }
  }

  async function showArtists() {
    selectLibrarySection("artists");
    libraryStack = [{ label: "Artists", render: showArtists }];
    const seq = startLibraryView("none");
    try {
      const data = await Subsonic.getArtists();
      if (seq !== libraryViewSeq) return;
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
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load artists: " + err.message);
    }
  }

  async function showArtistAlbums(artistId, artistName) {
    libraryStack.push({ label: artistName, render: () => showArtistAlbums(artistId, artistName) });
    const seq = startLibraryView("none"); // all of this artist's albums, unfiltered
    try {
      const data = await Subsonic.getArtist(artistId);
      if (seq !== libraryViewSeq) return;
      const albums = (data.artist && data.artist.album) || [];
      renderLibraryList(albums.map((al) => buildRow({
        thumbUrl: al.coverArt ? Subsonic.coverArtUrl(al.coverArt) : null,
        icon: "💿",
        title: al.name,
        sub: al.year ? String(al.year) : "",
        onClick: () => showAlbumSongs(al.id, al.name),
      })));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load albums: " + err.message);
    }
  }

  async function showAlbumSongs(albumId, albumName) {
    libraryStack.push({ label: albumName, render: () => showAlbumSongs(albumId, albumName) });
    const seq = startLibraryView("none"); // the album's full tracklist, unfiltered
    libraryResultRows = new Map();
    try {
      const data = await Subsonic.getAlbum(albumId);
      if (seq !== libraryViewSeq) return;
      const songs = (data.album && data.album.song) || [];
      renderLibraryList(songs.map(songRow));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load tracks: " + err.message);
    }
  }

  async function showFavorites() {
    selectLibrarySection("favorites");
    libraryStack = [{ label: "Favorites", render: showFavorites }];
    const seq = startLibraryView("songs");
    libraryResultRows = new Map();
    try {
      const data = await Subsonic.getStarred2();
      if (seq !== libraryViewSeq) return;
      const songs = (data.starred2 && data.starred2.song) || [];
      if (!songs.length) {
        renderLibraryError("No favorites yet. Star a song anywhere in the library to add one.");
        return;
      }
      const filtered = applyLibraryFilters(songs);
      if (!filtered.length) {
        renderLibraryError("No favorites match these filters.");
        return;
      }
      renderLibraryList(filtered.map(songRow));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load favorites: " + err.message);
    }
  }

  // Merges both play counters, since neither one alone sees every play:
  //  - Navidrome's own playCount (fed by scrobble, see playIndex and the
  //    "ended" handler) covers local songs played from ANY Subsonic client
  //    (Navidrome's web UI, a phone app) and from before PiTune counted
  //    anything, but knows nothing about a YouTube track until it's saved.
  //  - PiTune's own counter (main.py's /api/playcount, see recordPlay)
  //    covers YouTube tracks, plus any local play whose scrobble never
  //    landed.
  // A local song played in PiTune is counted by BOTH (recordPlay and the
  // scrobble fire on the same natural finish), so adding the two would
  // double-count it; the larger of the two is its count instead.
  //
  // Subsonic has no per-song "most played" call (getTopSongs is one
  // artist's popularity, not play counts), so Navidrome's side comes from
  // its most played ALBUMS (getAlbumList2 "frequent", where an album's
  // count is the sum of its songs' plays): their songs' own playCounts,
  // re-ranked. Best-effort: a heavily played song on an album that isn't
  // among the MOST_PLAYED_ALBUM_POOL most played albums overall is missed,
  // which takes an unusually lopsided library to matter. Local songs are
  // always shown with fresh Navidrome metadata (getSong for any PiTune-
  // counted song that pool didn't include) rather than a second, drift-
  // prone copy of title/artist/cover kept in PiTune; one deleted since it
  // was last played fails getSong and is just left out.
  const MOST_PLAYED_SONG_COUNT = 20;
  const MOST_PLAYED_ALBUM_POOL = 30;

  async function fetchPituneTopPlays() {
    // Headroom past MOST_PLAYED_SONG_COUNT for ties at the cutoff once
    // merged with Navidrome's counts.
    const res = await fetch(`api/playcount/top?limit=${MOST_PLAYED_SONG_COUNT * 2}`);
    if (!res.ok) throw new Error(await res.text());
    return (await res.json()).results;
  }

  async function fetchNavidromeTopSongs() {
    const data = await Subsonic.getAlbumList2("frequent", MOST_PLAYED_ALBUM_POOL);
    const albums = (data.albumList2 && data.albumList2.album) || [];
    const albumDetails = (await Promise.allSettled(albums.map((al) => Subsonic.getAlbum(al.id))))
      .filter((r) => r.status === "fulfilled").map((r) => r.value);
    return albumDetails.flatMap((detail) => (detail.album && detail.album.song) || []).filter((s) => s.playCount > 0);
  }

  async function showMostPlayed() {
    selectLibrarySection("most-played");
    libraryStack = [{ label: "Most Played", render: showMostPlayed }];
    const seq = startLibraryView("none");
    libraryResultRows = new Map();
    try {
      // allSettled: either side failing on its own (the backend restarting,
      // Navidrome mid-scan) still shows the other's plays instead of nothing.
      const [pitune, navidrome] = await Promise.allSettled([fetchPituneTopPlays(), fetchNavidromeTopSongs()]);
      if (seq !== libraryViewSeq) return;
      if (pitune.status === "rejected" && navidrome.status === "rejected") throw pitune.reason;
      [pitune, navidrome].filter((r) => r.status === "rejected")
        .forEach((r) => console.warn("Most Played is missing one side's play counts:", r.reason));

      const local = new Map(); // songId -> {song, count}
      (navidrome.status === "fulfilled" ? navidrome.value : []).forEach((s) => local.set(s.id, { song: s, count: s.playCount }));
      const youtube = [];
      (pitune.status === "fulfilled" ? pitune.value : []).forEach((r) => {
        if (r.source === "youtube") { youtube.push({ youtube: r, count: r.count }); return; }
        const known = local.get(r.id);
        if (known) known.count = Math.max(known.count, r.count);
        else local.set(r.id, { song: null, count: r.count });
      });
      await Promise.all([...local].filter(([, e]) => !e.song).map(async ([id, e]) => {
        try {
          e.song = (await Subsonic.getSong(id)).song;
          e.count = Math.max(e.count, e.song.playCount || 0);
        } catch {
          local.delete(id);
        }
      }));
      if (seq !== libraryViewSeq) return;

      const top = [...local.values(), ...youtube].sort((a, b) => b.count - a.count).slice(0, MOST_PLAYED_SONG_COUNT);
      if (!top.length) {
        renderLibraryError("Nothing played yet. Plays from PiTune (library and YouTube alike) and from any other Navidrome client all count, so this fills in as you listen.");
        return;
      }
      renderLibraryList(top.map((e) => (e.youtube
        ? buildYtRow(
          { id: e.youtube.id, title: e.youtube.title, artist: e.youtube.artist, thumbnail: e.youtube.thumbnail, channelId: null, duration: null, viewCount: null },
          { rowMap: libraryResultRows, extraSub: ` · ${e.count} play${e.count === 1 ? "" : "s"}` },
        )
        // The merged count, which is what this list is ranked by, rather
        // than Navidrome's alone.
        : songRow({ ...e.song, playCount: e.count }))));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load most-played: " + err.message);
    }
  }

  // "Newest" per getAlbumList2 is ALBUM-level (when Navidrome's scanner
  // first indexed it), which isn't the same thing as the individual SONGS
  // most recently added; one freshly-downloaded YouTube track usually
  // lands in an existing/generic album grouping (yt-dlp's extracted
  // metadata rarely tags a real album), so showing recent ALBUMS mostly
  // surfaced old, unrelated ones instead. Songs do carry their own
  // `created` timestamp, just not through any endpoint that sorts by it
  // directly, so this pulls songs from the N most recently touched
  // albums and re-sorts by each song's own created date, which is close
  // enough in practice: a genuinely-new song's album is always among the
  // most recently touched ones too.
  const RECENTLY_ADDED_ALBUM_POOL = 30;
  const RECENTLY_ADDED_SONG_COUNT = 10;

  async function showRecentlyAdded() {
    selectLibrarySection("recent");
    libraryStack = [{ label: "Recently Added", render: showRecentlyAdded }];
    const seq = startLibraryView("songs");
    libraryResultRows = new Map();
    try {
      const albumData = await Subsonic.getAlbumList2("newest", RECENTLY_ADDED_ALBUM_POOL);
      const albums = (albumData.albumList2 && albumData.albumList2.album) || [];
      // allSettled, not all: one bad album (removed mid-scan, say)
      // must not abort every other album's songs along with it.
      const albumDetails = (await Promise.allSettled(albums.map((al) => Subsonic.getAlbum(al.id))))
        .filter((r) => r.status === "fulfilled").map((r) => r.value);
      if (seq !== libraryViewSeq) return;
      const songs = applyLibraryFilters(albumDetails.flatMap((detail) => (detail.album && detail.album.song) || []));
      songs.sort((a, b) => new Date(b.created || 0) - new Date(a.created || 0));
      if (!songs.length) {
        renderLibraryError("No recently added songs match these filters.");
        return;
      }
      renderLibraryList(songs.slice(0, RECENTLY_ADDED_SONG_COUNT).map(songRow));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load recently added songs: " + err.message);
    }
  }

  async function showPlaylists() {
    selectLibrarySection("playlists");
    libraryStack = [{ label: "Playlists", render: showPlaylists }];
    const seq = startLibraryView("none");
    try {
      const data = await Subsonic.getPlaylists();
      if (seq !== libraryViewSeq) return;
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
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load playlists: " + err.message);
    }
  }

  async function showPlaylistDetail(playlistId, name) {
    libraryStack.push({ label: name, render: () => showPlaylistDetail(playlistId, name) });
    const seq = startLibraryView("songs");
    libraryResultRows = new Map();
    try {
      const data = await Subsonic.getPlaylist(playlistId);
      if (seq !== libraryViewSeq) return;
      const songs = (data.playlist && data.playlist.entry) || [];
      if (!songs.length) {
        renderLibraryError("This playlist is empty. Use a song's 📋 button anywhere in the library to add one.");
        return;
      }
      const filtered = applyLibraryFilters(songs);
      if (!filtered.length) {
        renderLibraryError("No songs in this playlist match these filters.");
        return;
      }
      // Play/Shuffle act on the FILTERED list, matching what's actually
      // shown below, not the playlist's full, unfiltered contents.
      const controls = document.createElement("li");
      controls.className = "library-action-row";
      const playBtn = document.createElement("button");
      playBtn.textContent = "▶ Play all";
      playBtn.addEventListener("click", () => playTracks(filtered.map(songToTrack)));
      const shuffleBtn = document.createElement("button");
      shuffleBtn.textContent = "🔀 Shuffle";
      shuffleBtn.addEventListener("click", () => playTracks(filtered.map(songToTrack), { shuffle: true }));
      controls.appendChild(playBtn);
      controls.appendChild(shuffleBtn);
      renderLibraryList([controls, ...filtered.map(songRow)]);
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Could not load playlist: " + err.message);
    }
  }

  const librarySections = {
    songs: showSongsSection, albums: showAlbumsSection, artists: showArtists,
    favorites: showFavorites, recent: showRecentlyAdded, "most-played": showMostPlayed,
    playlists: showPlaylists,
  };
  document.querySelectorAll(".library-nav-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.getElementById("library-search-input").value = "";
      librarySections[btn.dataset.section]();
    });
  });

  // ── Library search (Subsonic search3) ───────────────────────────────
  // Searches across the whole library regardless of which sidebar section
  // is active; clearing the box goes back to whichever section's button is
  // still marked active (its render() was never replaced, just not run
  // while a search was showing instead).
  document.getElementById("library-search-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const query = document.getElementById("library-search-input").value.trim();
    const list = document.getElementById("library-list");
    if (!query) {
      const activeBtn = document.querySelector(".library-nav-btn.active");
      if (activeBtn) librarySections[activeBtn.dataset.section]();
      return;
    }
    libraryStack = [{ label: `Search: ${query}`, render: () => document.getElementById("library-search-form").requestSubmit() }];
    const seq = startLibraryView("songs");
    list.innerHTML = "";
    libraryResultRows = new Map();
    const loading = document.createElement("li");
    loading.className = "item-sub";
    loading.textContent = "Searching…";
    list.appendChild(loading);
    try {
      const data = await Subsonic.search3(query);
      if (seq !== libraryViewSeq) return;
      const songs = (data.searchResult3 && data.searchResult3.song) || [];
      if (!songs.length) {
        renderLibraryError(`No songs matched "${query}".`);
        return;
      }
      const filtered = applyLibraryFilters(songs);
      if (!filtered.length) {
        renderLibraryError(`"${query}" matched songs, but none of them match the current filters.`);
        return;
      }
      renderLibraryList(filtered.map(songRow));
    } catch (err) {
      if (seq !== libraryViewSeq) return;
      renderLibraryError("Search failed: " + err.message);
    }
  });

  // ── YouTube search ──────────────────────────────────────────────────
  // ytView holds whichever of the two YouTube-tab views is current: a text
  // search, or a channel's uploads (opened from a search result's 📺
  // button). Both are rendered through the same renderYtView()/buildYtRow()
  // pair, since /api/search and /api/channel/{id} return the same result
  // shape (see main.py's _entry_to_result) and behave the same way for
  // sort/duration/upload_date filters and "load more".
  //
  // "Load more" grows `limit` and re-fetches+re-renders the WHOLE list from
  // scratch rather than appending just the new tail: neither endpoint
  // exposes a real cursor (neither YouTube's search nor a channel's uploads
  // list offers one through yt-dlp), and sort=views in particular can
  // legitimately promote a video that only showed up once more candidates
  // were considered, which a simple append would never reorder into place.
  let ytView = null;
  // trackKey -> <li>, only ever holding the CURRENTLY rendered view's rows;
  // replaced wholesale on every renderYtView() so updateNowPlayingHighlights
  // (in the player section above) never touches a stale/removed row.
  let ytResultRows = new Map();
  // Bumped by every renderYtView(). Without it, whichever request happened
  // to finish LAST won: a slow search overwrote a quicker one started
  // after it (a new query, a filter change, opening a channel).
  let ytRenderSeq = 0;

  const YT_SEARCH_BATCH = 20;
  const YT_CHANNEL_BATCH = 30;

  function currentYtFilters() {
    return {
      sort: document.getElementById("yt-filter-sort").value,
      duration: document.getElementById("yt-filter-duration").value,
      uploadDate: document.getElementById("yt-filter-date").value,
    };
  }

  // One filter bar serves both views, so it has to show the filters of
  // whichever view is on screen: "← Search results" brings the search back
  // with ITS OWN filters, and the dropdowns used to keep showing whatever
  // had last been picked for the channel instead.
  function syncYtFilterControls(view) {
    document.getElementById("yt-filter-sort").value = view.sort;
    document.getElementById("yt-filter-duration").value = view.duration;
    document.getElementById("yt-filter-date").value = view.uploadDate;
  }

  async function fetchYtSearch(view) {
    const params = new URLSearchParams({
      q: view.query, limit: view.limit, sort: view.sort,
      duration: view.duration, upload_date: view.uploadDate,
    });
    const res = await fetch(`api/search?${params.toString()}`);
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  async function fetchYtChannel(view) {
    const params = new URLSearchParams({
      limit: view.limit, sort: view.sort, duration: view.duration, upload_date: view.uploadDate,
    });
    const res = await fetch(`api/channel/${view.channelId}?${params.toString()}`);
    if (!res.ok) throw new Error(await res.text());
    return res.json();
  }

  // Opens a search result's uploader as its own browsable view; `previous`
  // is the search view being left, so the "← Search results" breadcrumb (see
  // renderYtBreadcrumb) can return to it exactly as it was, filters and
  // "load more" progress included, instead of resetting the search. It
  // starts with the filter bar's current values, which are what the bar is
  // showing; it used to start with none at all, which sent the literal
  // string "undefined" for every filter and got a 422 back from the backend.
  function openChannel(channelId, channelName, previous) {
    ytView = {
      kind: "channel", channelId, channelName: channelName || "", limit: YT_CHANNEL_BATCH, previous,
      ...currentYtFilters(),
    };
    renderYtView();
  }

  // options lets callers outside the YouTube tab's own view (Most Played,
  // see showMostPlayed) reuse this without depending on module-level
  // `ytView`: showChannelButton/extraSub/rowMap are all decided by the
  // caller instead of inferred from whatever view happens to be current.
  function buildYtRow(r, { showChannelButton = false, extraSub = "", rowMap = ytResultRows } = {}) {
    const track = {
      title: r.title, artist: r.artist, src: `api/stream/${r.id}`, source: "youtube",
      videoId: r.id, thumbUrl: r.thumbnail,
    };
    const views = r.viewCount != null ? ` · ${formatViewCount(r.viewCount)} views` : "";
    const age = r.uploadedAt ? ` · ${formatAge(r.uploadedAt)}` : "";
    const actions = [
      { icon: "＋", title: "Add to queue", className: "item-queue", onClick: () => addToQueue(track) },
      { icon: "⬇", title: "Save to library", className: "item-save", onClick: (btn) => saveToLibraryManually(r.id, btn) },
    ];
    if (r.channelId && showChannelButton) {
      actions.push({
        icon: "📺", title: `View uploads from ${r.artist || "this channel"}`, className: "item-channel",
        onClick: () => openChannel(r.channelId, r.artist, ytView),
      });
    }
    const row = buildRow({
      thumbUrl: r.thumbnail, icon: "▶", title: r.title,
      sub: (r.artist || "") + views + age + extraSub,
      durationText: r.duration ? formatTime(r.duration) : "",
      onClick: () => enqueue(track),
      actions,
    });
    // Registered for live now-playing highlighting (see
    // updateNowPlayingHighlights) in the map of the list it's rendered
    // into: the YouTube tab's own by default, the Library's for Most Played,
    // so it's cleared along with that list rather than going stale here.
    rowMap.set(trackKey(track), row);
    return row;
  }

  function renderYtBreadcrumb() {
    const el = document.getElementById("yt-breadcrumb");
    el.innerHTML = "";
    if (ytView.kind !== "channel") {
      el.classList.add("hidden");
      return;
    }
    const back = document.createElement("button");
    back.textContent = "← Search results";
    back.addEventListener("click", () => {
      if (ytView.previous) { ytView = ytView.previous; renderYtView(); }
    });
    el.appendChild(back);
    const label = document.createElement("span");
    label.className = "item-sub";
    label.textContent = ytView.channelName ? `Uploads from ${ytView.channelName}` : "Channel uploads";
    el.appendChild(label);
    el.classList.remove("hidden");
    if (!ytView.previous) back.disabled = true; // opened with nothing to go back to (shouldn't normally happen)
  }

  // loadMore: fetch the next, bigger batch while the current results stay
  // on screen, instead of the list emptying out to a "Searching…" line
  // (which also threw the scroll position back to the top, i.e. back
  // above everything already seen).
  async function renderYtView({ loadMore = false } = {}) {
    const seq = ++ytRenderSeq;
    const view = ytView;
    const list = document.getElementById("yt-results");
    const loadMoreBtn = document.getElementById("yt-load-more");
    // Only committed to view.limit once it has actually loaded, so a failed
    // "load more" can simply be retried without skipping a batch.
    const limit = loadMore ? view.limit + (view.kind === "channel" ? YT_CHANNEL_BATCH : YT_SEARCH_BATCH) : view.limit;
    syncYtFilterControls(view);
    renderYtBreadcrumb();
    if (loadMore) {
      loadMoreBtn.disabled = true;
      loadMoreBtn.textContent = "Loading…";
    } else {
      list.innerHTML = "";
      ytResultRows = new Map();
      loadMoreBtn.classList.add("hidden");
      const loading = document.createElement("li");
      loading.className = "item-sub";
      loading.textContent = view.kind === "channel" ? "Loading channel…" : "Searching…";
      list.appendChild(loading);
    }

    try {
      const request = { ...view, limit };
      const data = view.kind === "channel" ? await fetchYtChannel(request) : await fetchYtSearch(request);
      if (seq !== ytRenderSeq) return; // a newer search/filter/view has started since; see ytRenderSeq
      view.limit = limit;
      if (view.kind === "channel" && data.channelName) {
        view.channelName = data.channelName;
        renderYtBreadcrumb(); // may have opened with only the search-row's artist name as a guess
      }
      const scroller = document.querySelector("main");
      const scrollTop = scroller.scrollTop;
      list.innerHTML = "";
      ytResultRows = new Map();
      if (!data.results.length) {
        const empty = document.createElement("li");
        empty.className = "item-sub";
        empty.textContent = view.kind === "channel"
          ? "No uploads match these filters."
          : "No results.";
        list.appendChild(empty);
        loadMoreBtn.classList.add("hidden");
        return;
      }
      data.results.forEach((r) => list.appendChild(buildYtRow(r, { showChannelButton: view.kind === "search" })));
      if (loadMore) scroller.scrollTop = scrollTop;
      updateNowPlayingHighlights();
      loadMoreBtn.classList.toggle("hidden", !data.hasMore);
      loadMoreBtn.disabled = false;
      loadMoreBtn.textContent = "Load more";
    } catch (err) {
      if (seq !== ytRenderSeq) return;
      if (loadMore) {
        // Keep the results already showing; the button itself is the retry.
        loadMoreBtn.disabled = false;
        loadMoreBtn.textContent = "Load more (failed, tap to retry)";
        return;
      }
      list.innerHTML = "";
      const errEl = document.createElement("li");
      errEl.className = "item-sub";
      errEl.textContent = (view.kind === "channel" ? "Could not load channel: " : "Search failed: ") + err.message;
      list.appendChild(errEl);
    }
  }

  document.getElementById("yt-search-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const q = document.getElementById("yt-search-input").value.trim();
    if (!q) return;
    ytView = { kind: "search", query: q, limit: YT_SEARCH_BATCH, ...currentYtFilters() };
    renderYtView();
  });

  // Changing a filter restarts the current view from its first batch (not
  // wherever "Load more" had grown it to), the same thing changing a filter
  // on YouTube's own site does.
  ["yt-filter-sort", "yt-filter-duration", "yt-filter-date"].forEach((id) => {
    document.getElementById(id).addEventListener("change", () => {
      if (!ytView) return;
      Object.assign(ytView, currentYtFilters());
      ytView.limit = ytView.kind === "channel" ? YT_CHANNEL_BATCH : YT_SEARCH_BATCH;
      renderYtView();
    });
  });

  document.getElementById("yt-load-more").addEventListener("click", () => {
    if (!ytView) return;
    renderYtView({ loadMore: true });
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
