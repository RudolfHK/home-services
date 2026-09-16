# PiTune Discover: audio tagging & similarity, research and plan

Research and design only. Nothing in this document has been implemented; it
extends README.md's existing "Discover (not yet implemented)" section (the
two-pass audio-analysis + Annoy design already scaffolded in `app/main.py`'s
`/api/discover/*` stubs and `app.js`'s Discover tab) into a concrete,
hardware-verified plan for genre/mood/BPM/key tagging and tag-based
filtering and playlist creation, the way Spotify's own audio-features API
and genre tags work.

The single biggest finding: **the "obvious" library for this (Essentia's
pretrained TensorFlow genre/mood models, which the existing Discover
scaffolding's own comments point at) has no Linux ARM64 build at all**,
pip-installable or otherwise; see "Library feasibility on Pi 5" below. That
one fact reshapes the whole plan away from "install a pretrained model" and
toward a tiered approach where the cheap, fully-DSP tiers (BPM, key,
energy) are the reliable core, and true genre/mood classification is a
real, scoped follow-on project, not a pip install.

## Contents

1. [Current state](#current-state)
2. [Hardware/environment constraints](#hardwareenvironment-constraints)
3. [Library feasibility on Pi 5 (the actual research)](#library-feasibility-on-pi-5-the-actual-research)
4. [What to tag, in tiers](#what-to-tag-in-tiers)
5. [Where tags live: storage design](#where-tags-live-storage-design)
6. [Pipeline architecture](#pipeline-architecture)
7. [API design](#api-design)
8. [Frontend/UX plan](#frontendux-plan)
9. [Performance & resource budget](#performance--resource-budget)
10. [Licensing](#licensing)
11. [Phased roadmap](#phased-roadmap)
12. [Open questions for whoever implements this](#open-questions-for-whoever-implements-this)
13. [Sources](#sources)

## Current state

- `pihub/pitune/backend/app/main.py` has three stub endpoints
  (`POST /api/discover/analyze`, `GET /api/discover/status`,
  `GET /api/discover/similar/{track_id}`), all returning 501/placeholder
  data. No model is loaded, nothing runs.
- `pihub/pitune/frontend/src/app.js` has a Discover tab with an "Analyze
  library" button, wired but `disabled`, and empty render functions
  (`discoverStartAnalysis`, `discoverPollStatus`, `discoverRenderResults`).
- PiTune already has two pieces of infrastructure this plan reuses directly
  rather than reinventing:
  - **A persistent bind-mounted data directory** (`PITUNE_DATA_PATH`,
    currently holding `play_counts.json` for PiTune's own play counter,
    see the commit that added it). The tag/feature database belongs next
    to it.
  - **A fire-and-forget background job + polling status pattern**
    (`POST /api/save/{id}` + `GET /api/save/{id}/status`, backed by
    `_SAVE_PROGRESS`/`threading.Lock`). `/api/discover/analyze` +
    `/api/discover/status` should follow the exact same shape, not a new
    pattern.
  - **A library filter bar** (artist/duration/year, client-side, see
    `applyLibraryFilters` in app.js) that a tag/BPM/key filter extends
    rather than replaces.
- Navidrome (the actual library backend) has its own **custom tags**
  feature (`https://www.navidrome.org/docs/usage/configuration/custom-tags/`)
  for mapping extra ID3/Vorbis-comment fields into filterable attributes.
  I could not fetch that page directly (blocked by this sandbox's egress
  proxy for that domain), so the exact config schema below is from search
  snippets and general knowledge of Navidrome, not a verified read of the
  current doc. **Verify it against Navidrome's live docs before committing
  to the "write tags back into files" architecture** (see
  [Where tags live](#where-tags-live-storage-design)).

## Hardware/environment constraints

- Raspberry Pi 5: quad-core Cortex-A76 @ 2.4 GHz, no usable GPU for this
  (the VideoCore VII GPU has no accessible ML inference path this stack
  could reasonably target), 4 GB or 8 GB RAM depending on the board bought.
- README.md already states an idle-RAM target of ~1.5 GB across Core +
  PiTune + Jellyfin on a 4 GB Pi 5. Whatever this adds needs to stay
  dormant (near-zero extra RAM/CPU) when analysis isn't actively running,
  since it's explicitly a manually-triggered action, not a background
  service.
- `pitune-backend`'s image is `python:3.12-slim` (Debian 12 "bookworm",
  glibc 2.36) on `linux/arm64` when built on a Pi. Every dependency below
  is checked against THAT combination specifically: glibc 2.36 satisfies
  every `manylinux_2_17`/`_2_27`/`_2_28` aarch64 wheel found below.
- No GPU means every model considered has to be a CPU-inference story.
  That's the deciding factor behind recommending ONNX Runtime over
  PyTorch/TensorFlow directly (see below): it's built for exactly this.

## Library feasibility on Pi 5 (the actual research)

Checked directly against PyPI's file listings for `linux_aarch64`/
`manylinux_*_aarch64` wheels (not assumed from memory), since this is the
one thing that can quietly sink the whole feature on install day:

| Package | Linux aarch64 wheel? | Notes |
|---|---|---|
| `essentia` | **No** | Only `manylinux2014_x86_64` + macOS wheels exist (checked v2.1b6.dev1438). Source build only, and Essentia's build is a large, brittle C++ toolchain (FFTW, TensorFlow C++, Chromaprint, etc.), not something to ask a Pi self-hoster to do. |
| `essentia-tensorflow` (the package with the pretrained genre/mood/tempo models the existing Discover scaffolding's comments point at) | **No** | Same as above; also AGPL-3.0-only (see [Licensing](#licensing)). |
| `librosa` (BPM, key, chroma, MFCC, spectral features) | Yes (pure-Python wheel) | Its native-code dependencies are the real question; see `numba`, `soundfile`, `scipy` below. |
| `numba` (librosa's JIT-compiled inner loops) | **Yes**, `manylinux_2_27_aarch64` (checked v0.67.0) | This used to be the actual blocker (aarch64 wheels only landed on PyPI in the last few years; older guidance saying "numba has no aarch64 wheel, expect a slow LLVM source build" is now stale). |
| `soundfile` (audio file I/O) | **Yes**, `manylinux_2_28_aarch64` (checked v0.14.0, wheel added in 0.13.0) | |
| `scipy` / `scikit-learn` | Yes | Long-standing, solid aarch64 wheel support, not re-verified here since it's not in real doubt. |
| `onnxruntime` (CPU inference for a pretrained model, if Tier 3 is built) | **Yes**, `manylinux_2_28_aarch64` (checked v1.30.0, ~21 MB) | The practical way to run a pretrained model on a Pi without installing a multi-hundred-MB deep learning framework. |
| `torch` (if someone wanted to run a PyTorch model directly instead of converting to ONNX) | Yes, but **454 MB per aarch64 wheel** (checked v2.14.0), CPU-only builds not offered separately from the full GPU-capable wheel on Linux aarch64 | Technically installable, but a bad trade for a Pi image: 20x the size of the ONNX Runtime wheel for the same CPU-only inference job. Convert to ONNX once on a dev machine instead; never install PyTorch on the Pi itself. |
| `annoy` (the ANN library the existing scaffolding already names) | No published wheel past 2023 for any Linux target shown on PyPI; last release 1.17.3 (Jun 2023) | Small, dependency-free C++ extension; builds from source in seconds with `build-essential` + Python headers, unlike Essentia. Still, its apparent maintenance stall is worth weighing against `hnswlib` (also source-build-only, last release Dec 2023, equally simple) or `usearch` (more actively maintained, worth a fresh check at implementation time). None of these three is a hard blocker; they're all a `RUN apt-get install build-essential` line away, same pattern as `pitune-backend`'s own Dockerfile already uses for `ffmpeg`. |

**Conclusion**: the DSP tier (librosa + numba + soundfile) and the ONNX
Runtime inference tier are both cleanly pip-installable on a real Pi 5
build. Essentia, the library the *existing* Discover scaffolding's own
comments implicitly assumed, is not, and shouldn't be attempted via a
source build. This is the main course-correction this research produces.

## What to tag, in tiers

Ordered by cost/reliability, not by how "impressive" they sound; each
tier is independently useful and shippable without the next one existing.

### Tier 0: metadata already on the file, free

- Existing ID3 `genre` tag, when present. Real for library tracks ripped
  with proper tagging; **essentially never present for YouTube-sourced
  saves** (yt-dlp's extracted metadata rarely includes a genre, the same
  gap already noted in this codebase's own "Recently Added" comment about
  albums). This is exactly why Tier 1/2 matter most for PiTune specifically:
  its single biggest source of untagged tracks is the YouTube save path,
  not ripped CDs.
- Year (already surfaced in the library filter bar's year range).

### Tier 1: pure DSP features (librosa only, no model)

Cheap, deterministic, no training data or model file needed, works on
100% of tracks regardless of source:

- **Tempo (BPM)**: `librosa.beat.beat_track`/`tempo`. The most directly
  "Spotify audio-features"-like number, and the single most requested kind
  of filter for building workout/party/chill playlists.
- **Musical key + mode** (e.g. "A minor"): chroma features
  (`librosa.feature.chroma_cqt`) correlated against Krumhansl-Schmuckler
  major/minor key profiles. Standard, well-understood DSP, not ML.
- **Energy / loudness**: RMS energy (`librosa.feature.rms`), normalized.
- **Danceability-ish heuristic**: beat strength/regularity from the same
  tempo-tracking pass (onset strength variance); a real number, but an
  approximation of what Spotify's own (proprietary, never fully published)
  danceability score means, so label it as an estimate, not a fact, in the UI.
- **Brightness/timbre summary**: spectral centroid + rolloff, mainly as
  INPUT to Tier 2's classifier below, not necessarily a user-facing tag on
  its own.
- **Duration bucket**: already exists in the library filter bar; no new
  work, just confirms the same buckets make sense for Discover results too.

This tier alone (BPM + key + energy) already satisfies a large fraction of
"filtering based on tags... creating playlists based on tags": a BPM
range and an energy level are both genuinely useful playlist filters on
their own, and neither needs a trained model, a dataset, or the ARM
dependency risk in Tier 2/3.

### Tier 2: classical genre/mood classifier (moderate effort, self-contained)

A small classifier (logistic regression / random forest / small MLP via
scikit-learn, all confirmed ARM-friendly above) trained on Tier 1's
hand-crafted features (MFCCs, chroma stats, spectral contrast, tempo,
zero-crossing rate) plus a small labeled reference set. GTZAN (10 genres,
~1000 tracks, long-standing academic benchmark) or FMA-small (8 genres,
larger) are the standard, freely available choices; check their exact
license terms before bundling either into this repo (see
[Licensing](#licensing)).

This is a real, if modest, ML task: train once (on a dev machine, not the
Pi), ship the trained model's weights (a few hundred KB to a few MB for
these classical model types, not a deep network) as a small file in the
repo or downloaded on first use, and run inference on-device with nothing
heavier than scikit-learn. Ceiling on accuracy and genre granularity is
real (GTZAN's 10 broad genres, not Spotify's hundreds of microgenres),
but it is fully self-contained, has no ARM-wheel risk, and directly
addresses the "most tracks have no genre tag at all" gap Tier 0 leaves
open.

### Tier 3: deep embeddings + true similarity search (highest fidelity, most effort)

This is what actually delivers "find tracks that sound like this one" and
fine-grained mood/subgenre tags close to what Spotify does, per the
existing Discover scaffolding's own design intent. Since Essentia's
pretrained models are off the table on ARM (see above), the credible path
is:

1. Take a pretrained reference model trained on an open, well-documented
   tagging dataset. **MTG-Jamendo** (55,000+ tracks, 87 genre tags, 56
   mood/theme tags, released by the same MTG/UPF group behind Essentia,
   but with independent PyTorch reference implementations that don't go
   through Essentia's C++/TensorFlow binaries at all) is the strongest
   candidate found.
2. **Convert it to ONNX once, offline, on a normal dev machine** (this is
   where PyTorch is allowed to exist, never on the Pi itself).
3. Ship only the resulting `.onnx` file (typically tens of MB for this
   model class) plus `onnxruntime` (~21 MB, confirmed aarch64 wheel above)
   to the Pi. The Pi never installs PyTorch, Essentia, or TensorFlow.
4. The embedding vector each track produces feeds **Annoy** (or `hnswlib`/
   `usearch`, all source-build-only on ARM but all simple, small builds,
   see the table above) for the actual "N nearest tracks" lookup, exactly
   as the existing scaffolding's comments already describe.

This is real, scoped engineering work (sourcing the right reference
checkpoint, doing the ONNX export and validating its outputs still match
the original model, sizing the resulting `.onnx` file against the "stay
small" goal), not a pip install, and not something to schedule alongside
Tier 1/2 in the same pass. Treat it as its own follow-on project once
Tier 1 (and optionally Tier 2) are live and the actual demand for
similarity search (vs. just tag filtering) is clearer from real usage.

## Where tags live: storage design

**Recommendation: a small SQLite database** at
`${PITUNE_DATA_PATH}/discover.db` (the same bind-mounted, backed-up
directory `play_counts.json` already lives in; see `scripts/backup.sh`),
not another flat JSON file. Reasoning:

- Tag/feature data needs actual queries ("tracks where bpm between 120 and
  130 AND mood = energetic"), which a flat JSON file makes awkward once
  the library is more than a few hundred tracks: you'd load-and-filter
  the whole file in Python on every request. SQLite gives real indexed
  queries essentially for free (stdlib `sqlite3`, no new dependency).
- One row per track: `track_id` (Navidrome song id or, for a YouTube
  track saved into the library, whatever id it gets once Navidrome scans
  it; analysis should run against **library files that exist on disk**,
  not YouTube search results, so this is always a Navidrome id, unlike
  PiTune's own play-count tracker which also has to handle un-saved
  YouTube video ids), plus columns for `bpm`, `key`, `mode`, `energy`,
  `danceability`, `genre` (Tier 2, nullable until that tier exists),
  `embedding` (Tier 3, a serialized vector, nullable), `analyzed_at`,
  and a content hash or `(file_path, mtime, size)` tuple so a re-run can
  skip already-analyzed, unchanged files (this is the resumability
  mechanism; see [Pipeline architecture](#pipeline-architecture)).
- Same atomic-write discipline already established for `play_counts.json`
  isn't needed here in the same way: SQLite's own journaling already
  gives crash-safety per write, which is actually a point in its favor
  over hand-rolling another temp-file-then-rename JSON scheme for a much
  bigger, more structured dataset.

**A second, complementary path worth real consideration**: writing
computed tags back into each file's own metadata (ID3 `TXXX` frames /
Vorbis comments, via `mutagen`, already a natural fit since it's a small,
pure-Python, ARM-friendly library) and configuring Navidrome's own custom
tags feature to expose them. Doing this would mean BPM/key/mood show up
in Navidrome's native UI and Subsonic API too, not just inside PiTune,
genuinely more useful than a PiTune-only silo. The trade-offs: it mutates
library files (a bigger blast radius than a side database: a bug here
could corrupt tags across the whole library, not just PiTune's own
data), it needs Navidrome's own scan to pick up the change before it's
visible anywhere (the same "tell Navidrome about it" gap already
documented for saved YouTube tracks), and **I could not verify Navidrome's
exact custom-tags config schema for this plan** (egress-blocked from
`navidrome.org` in this session), so confirm the real mechanism against
Navidrome's current docs before committing to this path. Recommendation:
build the SQLite-backed, PiTune-only version first (Tier 1/2, phase 1-2
below); revisit writing tags back to files as a later enhancement once
the tag set has stabilized, since changing your mind about a database
schema is trivial and changing your mind about already-rewritten file
tags is not.

## Pipeline architecture

Mirrors the existing `/api/save` fire-and-forget + polling pattern
directly, not a new design:

- `POST /api/discover/analyze` starts a background task (same
  `asyncio.ensure_future` + `_background_tasks` set pattern already used
  for saves) and returns immediately.
- The task **enumerates the library via the same Subsonic calls PiTune's
  own frontend already uses** (`getAlbumList2` paged, then `getAlbum` per
  album for its songs, the exact pattern `showSongsSection`/
  `loadMoreSongs` already implement client-side), not a new library-
  discovery mechanism. The backend needs its own Subsonic credentials for
  this (a config concern to resolve; see
  [Open questions](#open-questions-for-whoever-implements-this)), since
  today only the frontend talks to Navidrome directly.
- Each track: skip if already analyzed and unchanged (see the
  `(file_path, mtime, size)` check above); otherwise download/read the
  actual audio file (this needs read access to the same media library
  volume Navidrome reads from; pitune-backend currently only mounts
  `music/YouTube` read-write, not the whole `music/` tree, so it would need
  an additional **read-only** mount of the full library, following the
  same pattern the Navidrome/Jellyfin services already use), run Tier 1
  (and 2/3 once built) feature extraction, write the row to SQLite.
- **Bounded concurrency**, not "all four cores flat out": the Pi doing this
  in the background is still expected to serve normal playback/streaming
  requests during the run. A small worker pool (2 workers, leaving
  headroom) is a safer default than saturating every core; make it
  configurable (an env var, matching this repo's existing convention of
  exposing tunables like `SEARCH_RESULT_LIMIT`).
- `GET /api/discover/status` reports `{state, tracksTotal, tracksDone,
  currentTrack, startedAt, estimatedSecondsRemaining}`, richer than the
  existing save-progress shape since a library-wide job legitimately
  needs an ETA, not just a percent.
- Cancelable: a `POST /api/discover/cancel` (not in the original stub) is
  worth adding, since a library-wide job is long enough that "I started
  this by mistake" or "I need the CPU back right now" are real scenarios
  the existing save-progress flow never had to handle.

## API design

Building on the three existing stub routes:

- `POST /api/discover/analyze`: start (already stubbed; flesh out per
  above). Same `require_token` auth dependency as `/api/save`, since it's
  a real background job a blind cross-origin POST shouldn't be able to
  kick off.
- `GET /api/discover/status`: richer progress shape (above).
- `POST /api/discover/cancel`: new.
- `GET /api/discover/similar/{track_id}`: already stubbed; only
  meaningful once Tier 3 exists (needs an embedding + Annoy index).
  Returns 501 until then, same as today; no reason to change its
  contract early.
- `GET /api/discover/tags`: **new**. Returns the distinct values and
  counts for each taggable dimension (genres present, key list, BPM
  min/max/histogram buckets); what the frontend's filter panel populates
  its dropdowns/range sliders from, the same role
  `populateLibraryFilterArtists()` already plays for the artist filter.
- `GET /api/discover/tracks`: **new**. Query params for each tag
  dimension (`bpm_min`, `bpm_max`, `key`, `genre`, `mood` once Tier 2/3
  exist), returns matching track ids for the frontend to resolve via
  Subsonic's own `getSong` (exactly the pattern `showMostPlayed` already
  uses for its local entries) rather than duplicating song metadata in
  this response.
- Playlist creation from a tag query is **not a new backend endpoint**;
  it's frontend glue reusing `Subsonic.createPlaylist` +
  `Subsonic.addToPlaylist` (both already implemented) against whatever
  `GET /api/discover/tracks` returned, the same way "Play all"/"Shuffle"
  on a playlist already reuse existing queue primitives instead of adding
  new ones.

## Frontend/UX plan

- **Analyze library**: replace the disabled stub button with a real
  trigger; while running, show `GET /api/discover/status`'s progress
  (reusing the same `<progress>` element pattern already built for
  per-track save progress, just pointed at a library-wide job instead).
  A **Cancel** button next to it, backed by the new cancel endpoint.
- **Tag filter panel**: extends the just-shipped library filter bar
  (artist/duration/year, see `applyLibraryFilters`) with BPM range
  (two number inputs, same style as the year-from/year-to pair already
  there), key (a dropdown, populated from `/api/discover/tags`), and
  genre/mood (dropdowns, populated the same way, empty/hidden until Tier
  2 exists so the UI doesn't show controls for data that isn't there yet).
- **"Create playlist from these filters"** button next to the tag panel,
  reusing the existing playlist-modal (`openPlaylistCreateModal`) rather
  than a new dialog; the only new logic is fetching
  `GET /api/discover/tracks` first and batch-adding the results.
- **"Similar to this song"** action (📻 icon or similar), added to
  `songRowActions` alongside the existing star/queue/playlist actions,
  only shown once Tier 3 exists (feature-detect via `/api/discover/tags`
  or a capabilities flag, not a hardcoded UI toggle, so the button doesn't
  appear and immediately 501 for anyone who's only run Tier 1/2).

## Performance & resource budget

No Raspberry Pi 5-specific benchmark for librosa's typical per-track
feature-extraction time turned up in research for this document; treat
any number quoted for this as an estimate, not a verified fact, until
someone actually times it on real hardware. What the plan should do
instead of guessing a number and building around it:

- **Phase 0 of implementation should be a literal timing script**: run
  Tier 1 feature extraction against a 20-30 track sample on a real Pi 5,
  log wall-clock time per track, and use THAT to set defaults (worker
  count, whether to warn the user about a multi-hour first run on a
  large library, whether an ETA is even worth showing).
- Bound concurrency (2 workers suggested above) rather than 4, so
  Navidrome/PiTune streaming stays responsive during a run; this matters
  more on a Pi than it would on a server with headroom to spare.
- Cache the per-track "already analyzed, unchanged" check (the
  `(file_path, mtime, size)` tuple) so a second "Analyze library" run
  after adding a handful of new tracks costs seconds, not a full
  re-scan; this is the same "don't redo the expensive part" instinct
  behind PiTune's own yt-dlp extraction cache (`XDG_CACHE_HOME`) and the
  README's explicit "closer to transcoding every track once than a
  metadata scan" framing of why this stays manual.
- Whatever Tier 3 model gets chosen, budget its `.onnx` file size and
  peak RAM during inference explicitly against the existing ~1.5 GB idle
  target: a single inference pass loading a 100+ MB model file
  transiently is very different from that model staying resident, and the
  design should make sure it's the former (load once per analysis run,
  not once per track, but never keep it loaded outside an active run).

## Licensing

Worth flagging explicitly since a self-hosted project like this one is
exactly the kind of thing that gets its source shared or its image
redistributed:

- **Essentia / essentia-tensorflow: AGPL-3.0-only.** Beyond the ARM
  build problem, AGPL's copyleft terms are a real consideration for
  anyone distributing a built image or a fork, a reason to avoid it
  independent of the ARM finding above, not just because of it.
- **GTZAN / FMA** (candidate Tier 2 training sets): check each dataset's
  actual license/usage terms before bundling either into this repo or a
  built image, rather than assuming "commonly used in papers" means
  "freely redistributable"; that's a real distinction worth a deliberate
  check at implementation time, not an assumption made here.
- **MTG-Jamendo** (candidate Tier 3 source dataset/reference models):
  built from Jamendo's Creative-Commons-licensed catalog specifically for
  this kind of research reuse, the most favorable licensing story of the
  three, but still confirm the specific reference implementation's own
  license (code and trained weights can be licensed separately from the
  training data) before shipping anything derived from it.

## Phased roadmap

Each phase is independently shippable and useful; this isn't "build all
of it, then release":

1. **Phase 0, benchmark.** Timing script per above; also confirms the
   `librosa`/`numba`/`soundfile` install actually works cleanly in a real
   `python:3.12-slim` aarch64 build (this document's ARM findings are from
   PyPI's published wheel metadata, not a live build inside this sandbox,
   so it's worth one real confirmation build before committing further).
2. **Phase 1, Tier 1 (BPM/key/energy), SQLite storage, real
   analyze/status/cancel endpoints, library read access for
   pitune-backend.** Ships real, useful filtering (BPM range, key, energy)
   with the lowest-risk dependency set in this whole plan.
3. **Phase 2, filter panel + "create playlist from filters" UI** against
   Phase 1's data. This is where the feature actually becomes visible/
   useful to the user, not just a backend capability.
4. **Phase 3, Tier 2 classifier** (genre/mood for untagged, mostly
   YouTube-sourced tracks) once Phase 1/2 are validated in real use.
5. **Phase 4, Tier 3 embeddings + Annoy + "similar tracks."** The
   highest-effort, highest-fidelity piece, deliberately last: it's a real
   ML-engineering side project (sourcing a checkpoint, ONNX conversion,
   validation) rather than an extension of Phase 1-3's largely
   DSP/glue-code work, and by this point real usage data from Phases 1-3
   should make it clearer whether it's worth the effort at all.

## Open questions for whoever implements this

- **How does pitune-backend authenticate to Navidrome** for library
  enumeration and (if the file-tag-writeback path is ever pursued)
  triggering a rescan? Today only the *frontend* holds Subsonic
  credentials (the user's own, in `localStorage`). The backend doing this
  itself needs its own service account or token, a real new piece of
  config (an env var pair, following the existing `.env`
  convention), not something to improvise inline in the analyze
  endpoint.
- **Read access to the full media library from pitune-backend**: today it
  only mounts `music/YouTube` (read-write). Phase 1 needs (at minimum)
  read access to the whole `music/` tree, following the exact read-only
  mount pattern Navidrome/Jellyfin already use for it.
- Exact Tier 2/3 dataset and reference-model choices are named here as
  strong candidates (GTZAN/FMA, MTG-Jamendo), not final decisions;
  confirm current availability/licensing/quality at implementation time
  rather than treating this document's names as locked in months later.
- Whether "similar tracks" (Tier 3) is valuable enough to build at all
  is genuinely an open question until Phases 1-3 are live and real usage
  shows whether tag-based filtering alone already satisfies most of what
  people actually wanted from this feature.

## Sources

Checked directly against PyPI (file listings, `pypi.org/pypi/<pkg>/json`)
for every aarch64-wheel claim above, plus web search for context on
Navidrome's custom tags and candidate datasets/models:

- [essentia-tensorflow · PyPI](https://pypi.org/project/essentia-tensorflow/)
- [essentia · PyPI](https://pypi.org/project/essentia/)
- [numba · PyPI](https://pypi.org/project/numba/)
- [librosa · PyPI](https://pypi.org/project/librosa/)
- [soundfile · PyPI](https://pypi.org/project/soundfile/)
- [onnxruntime · PyPI](https://pypi.org/project/onnxruntime/)
- [torch · PyPI](https://pypi.org/project/torch/)
- [annoy · PyPI](https://pypi.org/project/annoy/)
- [hnswlib · PyPI](https://pypi.org/project/hnswlib/)
- [Using custom tags with Navidrome](https://www.navidrome.org/docs/usage/configuration/custom-tags/) (search-snippet only; direct fetch was blocked by this sandbox's egress proxy, re-verify before implementing)
- [The MTG-Jamendo Dataset for Automatic Music Tagging](https://www.academia.edu/101860503/The_MTG_Jamendo_Dataset_for_Automatic_Music_Tagging)
- [A collection of TensorFlow models for Essentia · Essentia Labs](https://mtg.github.io/essentia-labs/news/tensorflow/2020/01/16/tensorflow-models-released/)
