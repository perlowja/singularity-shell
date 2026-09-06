# OCS Wallpaper Browser + Import Implementation Plan

**Execution:** Sole worker, sequential tasks, no Hive or concurrent agents, per operator.

**Goal:** Browse the shipped OCS providers and usable desktop categories, preview wallpapers, and import a pack into the existing Wallpaper Source selector.

**Architecture:** A pure `WallpaperOcs` JSON adapter and `WallpaperOcsImports` state model in core; a GTK4 browser window launched by a Desktop settings row. Invoke the installed CLI with argv and async GLib.Subprocess, never a shell command string. Read the backend's classified index; do not duplicate taxonomy, download selection, extraction, normalization, or collection registration in Vala. Async thumbnail requests are presentation only. Rediscover the existing collection registry on successful import.

**Tech Stack:** Vala, GTK4, GLib/GIO, Json-GLib, Gee, Soup 3, Meson/Ninja, GLib.Test, Debian Forky ARM64 Podman on ULTRA .88.

**Spec:** `docs/superpowers/specs/2026-09-04-wallpaper-pack-browser-ocs-design.md`, section 2. Sections 1/5 already shipped. Sections 3 (Bing market/history/pins) and 4 (curated apt catalog) are explicitly subsequent stages, not part of this OCS implementation.

**Branch:** `feat/wallpaper-ocs-browser`, based on shell `bd9dd7a`; desktop build base `c0ad702`, canonical `~/Projects/singularity-desktop` on ULTRA `192.168.207.88`.

## Global Constraints

- Read contract first: cix-installer `docs/OCS-WALLPAPER-BACKEND.md` and `assets/wallpaper/ncz-wallpaper-ocs`, verified against board .66. `providers` yields schema/providers; index yields schema/providers/entries with `ref=provider:id` and boolean `usable`; browse yields schema/provider/category/items; item metadata uses `preview`, not `preview1`; import yields pack_id/destination/collection/images/pack_json.
- Backend has `browse PROVIDER CATEGORY --pages N`, with no query/search argument. Label search “Filter loaded wallpapers”; fetch more via increasing bounded page count, deduplicate by provider + item ID. Do not imply server-side search.
- Backend already writes one `.collection` per pack. Preserve that authoritative registration rather than synthesizing a competing “My OCS Imports” aggregate. Label online origins in the browser; preserve existing active source and wallpaper on import. Do not silently apply a downloaded image.
- No daemon/backend changes. No new settings/state files. Successful import must be backed by a readable registered collection and image payload before showing Added. In-memory state prevents repeated imports within the browser; read existing pack provenance to recognize earlier imports.
- All JSON access validates node types before calling typed getters. Unsupported schema, missing identity, wrong provider/category, malformed output fail inline. Optional absent/null author/license/preview have honest defaults. Never fabricate a license.
- GTK changes are checked by real container compilation and live interaction, not a fabricated widget meson test. Pure core file MUST be in both main executable sources and its GLib.Test executable sources.
- Each remote browse cancels its predecessor; generation guards discard stale results and thumbnails. Timeout and process exit status are checked. Import is serialized; closing/browsing while import writes is disabled until completion to avoid orphaned or concurrent imports. Thumbnail work is bounded and cancellable; errors keep a placeholder.
- Commit author Jason Perlow <jperlow@gmail.com>, no attribution footer; commit and push stages before producing release artifact. Preserve pre-existing worktrees. Sequential zoder review if available; report unavailable review honestly.

---

### Task 1: Core models and failing contract tests

**Files:**
- Create `src/core/wallpaper_ocs.vala` (line 1).
- Create `tests/wallpaper_ocs_test.vala` (line 1).
- Modify `meson.build`: main source list after `wallpaper_rotation_state.vala` (base line 287); test block after wallpaper rotation test (base line 459).

**Interfaces:**
- `WallpaperOcs.providers(json)`, `.categories(index, provider)`, `.items(json, provider, category)`: typed lists; errors for invalid envelopes/identity; optional metadata stays optional.
- `WallpaperOcsImports.begin(key)`, `.fail(key)`, `.complete(key, json, collection_roots)`, `.is_added(key)`, `.busy`: reject duplicate/in-progress operations, retry after failure; validate import registration against `WallpaperCollections` and real paths. `.discover(collections)` reads backend `pack.json` provenance for earlier imports.

- [ ] **Step 1: Write failing tests first.** Include schema/type failures; provider identity/dedup; only usable categories for selected provider; absent/null metadata; duplicate items; wrong provider/category; valid empty list distinct from malformed data; import failure/retry, serialization, completion validation, persisted discovery. Use temporary fixture directories, remove them after tests.
- [ ] **Step 2: Observe RED on ULTRA.** Commit tests/Meson wiring and a minimal compileable API stub returning empty lists/false. Push; fetch on ULTRA. In a disposable `debian:forky` Podman test container install valac + GLib/Gee/Json development packages, compile exact core/test sources with valac and run `wallpaper-ocs-test`. Save nonzero output; compilation failure alone is not the desired RED evidence.
- [ ] **Step 3: Implement the model.** Match the actual backend contract above; do not use network or user environment inside parser methods. Explicit paths injected into discovery/completion enable isolated tests.
- [ ] **Step 4: Observe GREEN.** Repeat exact container test; every case passes. Confirm existing wallpaper suites also pass later in canonical build. Verify both main and test source lists contain the new core file.
- [ ] **Step 5: Commit.** `git add src/core/wallpaper_ocs.vala tests/wallpaper_ocs_test.vala meson.build`; `git commit -m 'feat(wallpaper): parse OCS browser state'`; push branch.

---

### Task 2: GTK browser and async helper integration

**Files:**
- Create `src/components/sidebar/pages/wallpaper_ocs_browser.vala` (line 1).
- Modify `meson.build` main sources after desktop_page (base line 313).

**Interfaces:**
- Browser constructor takes owning application and collection roots; emits `imported()` after verified helper success.
- Consumes Task 1 models, `/usr/local/bin/ncz-wallpaper-ocs`, `/usr/share/ncz-wallpapers/ocs-category-index.json`.

- [ ] **Step 1: Build the widget.** Header/close action, provider and category dropdowns with labels, filter entry, retry/refresh and load-more controls, scrolled thumbnail cards with title/uploader/provider/license and Import button. Show spinner/loading, empty state, no filter matches, network/parse errors and retry. Size window for .66; labels wrap/ellipsize, keyboard close works.
- [ ] **Step 2: Wire async argv commands.** Providers then index load, categories filter, browse; use CLI --pages (bounded). Read-only requests cancel on changes/close; timeout terminates helper and reaps it; no GTK work in worker threads. Thumbnails via Soup streaming capped bytes and reduced pixbuf dimensions; limit concurrent loads and cancel obsolete requests.
- [ ] **Step 3: Wire import.** Global serialization prevents duplicate backend directories. Show per-card progress/error/Added, preserve current source, emit imported only after real registry/payload validation. Persisted pack metadata enables Added after reopening. Busy imports block close/filter/provider/category and show explanation; timeout/error restores controls.
- [ ] **Step 4: Review event lifetimes.** Close cancels browse/thumbnails, stale callbacks never populate a different request; callbacks own necessary references. No interpolated shell commands or markup from provider strings.
- [ ] **Step 5: Commit and push.** Stage only browser + meson; conventional commit without AI footer.

---

### Task 3: Desktop entry and collection refresh

**Files:**
- Modify `src/components/sidebar/pages/desktop_page.vala`: fields around lines 24-32; registry/selector initialization lines 173-211.

**Interfaces:**
- Reuse `WallpaperCollections.parse`, `WallpaperRotationState`, existing `SelectionRow`; browser imported signal refreshes choices then calls existing populate_grid.

- [ ] **Step 1: Extract selector refresh.** Keep collection roots/source selector references; rediscover collections and rebuild selection choices using existing SelectionRow API or replace its child in a stable container. Preserve active ID and source-scoped gallery behavior from bd9dd7a.
- [ ] **Step 2: Add Browse Online Wallpapers row/button** immediately below Wallpaper Source. Keep one browser instance per page; present existing instance on repeated clicks. Successful imports refresh choices without changing wallpaper or rotation.
- [ ] **Step 3: Commit and push.** `git add src/components/sidebar/pages/desktop_page.vala`; `git commit -m 'feat(wallpaper): open OCS picker from settings'`.

---

### Task 4: Container build, review, and live verification

**Files:**
- Modify desktop superproject `subprojects/singularity-shell` gitlink, pinning tested shell commit.
- Create `docs/diagnostics/2026-09-06-wallpaper-ocs-browser.md` with actual commands/results and remaining work.

- [ ] **Step 1: Review sequentially.** Locate zoder invocation from prior reports; run focused review if available, fix findings and re-review. No concurrent workers/Hive. If unavailable, explicitly record limitation and inspect JSON error paths, close/cancel races, import registration and main-source wiring locally.
- [ ] **Step 2: Verify clean inputs.** Fetch published shell branch on ULTRA, update canonical submodule to exact commit; commit/push superproject gitlink on a new OCS branch. Confirm tracked tree clean and source pins. Do not include pre-existing installer artifacts.
- [ ] **Step 3: Build with requested real builder.** On ULTRA:
  ```sh
  SINGULARITY_SOURCE_DIR=/home/jasonperlow/Projects/singularity-desktop \
  OUT=/home/jasonperlow/singularity-ocs-evidence/20260906/build \
  /home/jasonperlow/isobuild/cix-installer/build/build-singularity.sh
  ```
  Save complete output and exit status. Expected link success, exit 0 and staged tarball. Run `meson test -C build --print-errorlogs` in the producing container before exit where available, or build/run new core suite separately in the matching Forky container; record exact distinction. Existing builder explicitly runs three existing wallpaper Meson suites. Inspect artifact hash, executable hash and shared-library dependencies.
- [ ] **Step 4: Snapshot board before deploy.** Inventory live process/hash, greetd/core count, mini settings (`dconf dump /dev/sinty/desktop/`), wallpaper config tree including absence of files, collection/pack inventory and rotator service state. Back up all `/opt/singularity` to a dated archive; stage payload separately, preserve NCZ schema overrides and installed editor, compile schemas/check dependencies before swapping.
- [ ] **Step 5: Deploy/watch.** Restart greetd and authenticate via normal session path. Watch >=5 minutes for stable desktop PID, active greetd, no new cores; immediately restore old prefix and restart if crash loop occurs.
- [ ] **Step 6: Actually interact on .66.** Open Desktop settings, launch browser; verify all providers, usable categories, populated thumbnails, provider/category rapid changes, filter/no matches/clear, load more, close/reopen and responsive UI. Click one real raster Import; observe progress and Added; check helper-generated pack/collection/provenance and selector membership; reopen and confirm Added. Select imported collection and a thumbnail, verify actual repaint. Exercise inline error/retry using a reversible controlled unavailable endpoint/helper test only if safe; otherwise report that state as unit/static only. No GTK meson target.
- [ ] **Step 7: Restore operator state.** Restore wallpaper URI/history/source/rotation settings and prior rotator service activity. Remove only the identified test-created import files if operator did not already own them; leave no settings drift. Recheck PID/core count and saved state equality.
- [ ] **Step 8: Record and publish evidence.** Report real RED/GREEN output, build exit/artifact hashes, live screenshots/actions and limitations, commits/remotes. Mark checked steps only when actually completed. Ensure all task code committed/pushed, clean status. Bing history and curated catalog remain follow-up work.

## Post-plan note

The old design's aggregate imports collection and server-side search are superseded here by the verified backend contract. This adapts UI to shipped tooling; it does not add backend behavior. If safe full integration cannot be verified, retain a committed stage and report the missing live checks instead of declaring completion.
