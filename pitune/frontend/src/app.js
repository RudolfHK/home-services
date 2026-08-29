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
      return `/rest/${endpoint}.view?${params.toString()}`;
    },
    streamUrl(id) { return this.url("stream", { id }); },
    coverArtUrl(id) { return this.url("getCoverArt", { id, size: 100 }); },
    async call(endpoint, extra) {
      const res = await fetch(this.url(endpoint, extra));
      const data = await res.json();
      const body = data["subsonic-response"];
      if (!body || body.status !== "ok") {
        throw new Error((body && body.error && body.error.message) || "Subsonic request failed");
      }
      return body;
    },
    ping() { return this.call("ping"); },
    getArtists() { return this.call("getArtists"); },
    getArtist(id) { return this.call("getArtist", { id }); },
    getAlbum(id) { return this.call("getAlbum", { id }); },
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
  function buildRow({ thumbUrl, icon, title, sub, durationText, onClick, onRemove }) {
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

    if (onRemove) {
      const btn = document.createElement("button");
      btn.className = "item-remove";
      btn.title = "Remove";
      btn.textContent = "✕";
      btn.addEventListener("click", (e) => { e.stopPropagation(); onRemove(); });
      li.appendChild(btn);
    }

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
        onRemove: () => {
          queue.splice(i, 1);
          if (i < queueIndex) queueIndex--;
          else if (i === queueIndex) { queueIndex = -1; audio.pause(); audio.removeAttribute("src"); }
          renderQueue();
          renderNowPlaying();
        },
      });
      if (i === queueIndex) row.classList.add("playing");
      list.appendChild(row);
    });
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

  document.getElementById("btn-playpause").addEventListener("click", () => {
    if (!audio.src) return;
    if (audio.paused) audio.play(); else audio.pause();
  });
  document.getElementById("btn-next").addEventListener("click", () => playIndex(queueIndex + 1));
  document.getElementById("btn-prev").addEventListener("click", () => {
    if (audio.currentTime > 3) { audio.currentTime = 0; return; }
    playIndex(queueIndex - 1);
  });
  audio.addEventListener("ended", () => playIndex(queueIndex + 1));
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

  async function initLibrary() {
    const creds = Subsonic.load();
    if (!creds) {
      document.getElementById("library-login").classList.remove("hidden");
      return;
    }
    try {
      await Subsonic.ping();
      document.getElementById("library-login").classList.add("hidden");
      document.getElementById("library-browser").classList.remove("hidden");
      showArtists();
    } catch (err) {
      Subsonic.clear();
      document.getElementById("library-login").classList.remove("hidden");
      document.getElementById("library-browser").classList.add("hidden");
      alert("Could not log in to Navidrome: " + err.message);
    }
  }

  document.getElementById("login-submit").addEventListener("click", async () => {
    const user = document.getElementById("login-user").value.trim();
    const pass = document.getElementById("login-pass").value;
    if (!user || !pass) return;
    Subsonic.save(user, pass);
    await initLibrary();
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

  async function showArtists() {
    libraryStack = [{ label: "Artists", render: showArtists }];
    renderBreadcrumbs();
    const data = await Subsonic.getArtists();
    const index = (data.artists && data.artists.index) || [];
    const artists = index.flatMap((idx) => idx.artist || []);
    renderLibraryList(artists.map((a) => buildRow({
      thumbUrl: a.coverArt ? Subsonic.coverArtUrl(a.coverArt) : null,
      icon: "🎤",
      title: a.name,
      sub: `${a.albumCount || 0} album${a.albumCount === 1 ? "" : "s"}`,
      onClick: () => showAlbums(a.id, a.name),
    })));
  }

  async function showAlbums(artistId, artistName) {
    libraryStack.push({ label: artistName, render: () => showAlbums(artistId, artistName) });
    renderBreadcrumbs();
    const data = await Subsonic.getArtist(artistId);
    const albums = (data.artist && data.artist.album) || [];
    renderLibraryList(albums.map((al) => buildRow({
      thumbUrl: al.coverArt ? Subsonic.coverArtUrl(al.coverArt) : null,
      icon: "💿",
      title: al.name,
      sub: al.year ? String(al.year) : "",
      onClick: () => showSongs(al.id, al.name),
    })));
  }

  async function showSongs(albumId, albumName) {
    libraryStack.push({ label: albumName, render: () => showSongs(albumId, albumName) });
    renderBreadcrumbs();
    const data = await Subsonic.getAlbum(albumId);
    const songs = (data.album && data.album.song) || [];
    renderLibraryList(songs.map((s) => buildRow({
      icon: "🎵",
      title: s.title,
      sub: s.artist,
      durationText: s.duration ? formatTime(s.duration) : "",
      onClick: () => enqueue({ title: s.title, artist: s.artist, src: Subsonic.streamUrl(s.id), source: "local" }),
    })));
  }

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
      const res = await fetch(`/api/search?q=${encodeURIComponent(q)}`);
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
        list.appendChild(buildRow({
          thumbUrl: r.thumbnail,
          icon: "▶",
          title: r.title,
          sub: r.artist,
          durationText: r.duration ? formatTime(r.duration) : "",
          onClick: () => enqueue({ title: r.title, artist: r.artist, src: `/api/stream/${r.id}`, source: "youtube" }),
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

  // ── Init ────────────────────────────────────────────────────────────
  renderQueue();
  renderNowPlaying();
  initLibrary();
})();
