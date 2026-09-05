# Wallpaper pack browser, OCS layer, and curated-pack catalog — design

**Status:** approved by operator 2026-09-04, spec written same day.
**Path:** architectural.
**Depends on:** PR #24 (`fix/wallpaper-picker-pack-registry`) — the recursive
pack-registry scan that made the wallpaper grid show anything at all. This
spec builds the browsing/selection/import UI on top of that fix and the
already-shipped collections backend.

## Background

`docs/WALLPAPER-PACKS.md` (cix-installer, commit `00a0600`, 2026-08-19)
settled the design for wallpaper packs, OCS browsing, and the Bing provider.
Backend is shipped and verified on hardware:

- `f02e390` — collections + time-of-day + Bing provider
- `60dec16` — artist packs ship their own collection in their own directory
- `0d8eed0` — selectable Bing feeds (per-market cache) + configurable
  rotation (`rotate-enabled` / `rotate-interval`, re-read every cycle,
  30s-clamped)
- `00a0600` — the design doc itself

Its own "REMAINING" list named five items. This spec covers items 2 and 3
(pack selector/rotation controls/Bing history browser; OCS browse+import),
plus a new fourth piece — curated-pack discovery/install — added during this
design's scoping conversation. Item 1 (the recursive scan itself) is PR #24,
already built and under review. Item 5 (the lockscreen seat-capabilities fix)
is unrelated to this spec.

No UI for any of this exists today. The Desktop settings page
(`src/components/sidebar/pages/desktop_page.vala`) has one wallpaper grid,
fed by `populate_grid()`, with no way to switch collections, browse OCS, or
install a new pack — that's the gap this spec closes.

## Scope

In scope:
1. A source selector on the Desktop page for switching between installed
   collections (packs, Bing, OCS imports).
2. OCS browse + one-click import, landing in a synthetic "My OCS Imports"
   collection.
3. Bing market selection + a chronological history browser with pin/unpin.
4. A curated-pack catalog (browse + apt-install NCZ-signed artist packs not
   yet installed).
5. Rotation on/off + interval controls, thin UI over the already-shipped
   daemon config files.

Out of scope (explicitly deferred, not forgotten):
- The `.pack.json` migration mentioned in the design doc (PR #24 already
  notes `.collection` stays authoritative until that lands; this spec reads
  the same registry PR #24 reads, no format change here).
- Any change to the rotator daemon (`ncz-wallpaper-rotate` /
  `ncz-wallpaper-daemon`, both in `cix-installer/post-install/45-wallpaper-rotator.sh`)
  beyond what's already shipped. The rotation toggle in this spec writes the
  same two files (`~/.config/ncz-wallpaper/rotate-enabled`,
  `rotate-interval`) the daemon already reads every cycle.
- Per-pack rotation scope (`rotation.scope: pack | global` from the design
  doc's future `.pack.json` schema). Today rotation is global regardless of
  the selected source, matching the shipped daemon; this spec does not add a
  per-source rotation toggle.

## Architecture

### 1. Source selector

A `Gtk.DropDown` (or `Gtk.ComboBoxText` if the surrounding page still uses
the older widget for consistency — match whatever `desktop_page.vala`
already uses for its other setting rows) placed directly above the existing
wallpaper grid. Populated from:

```
foreach installed collection (existing collection_dirs() + parsing already
    added by PR #24, extended to also read Name/Artist for display):
    add "<Name>" (or "<Name> — <Artist>" for a pack that declares one)
add separator
add "My OCS Imports" — ONLY if that synthetic collection is non-empty
add separator
add "Browse Online (OCS)…"
add "Get more artist packs…"
```

Selecting a normal collection re-runs the existing `populate_grid()` /
`scan_wallpaper_dir()` path scoped to that one collection's `Dir`, same
machinery as today, so the grid's rendering, thread-safety, and generation-
counter logic (`wallpaper_grid_generation`) are untouched. Selecting either
`…` entry swaps the page's content area into one of the two browse modes
below (a `Gtk.Stack` with three children: `grid`, `ocs_browse`,
`catalog_browse`, matching however the page already switches between its
existing sub-sections — check the existing stack/notebook pattern in the
file before adding a new one).

### 2. OCS browse mode

Layout: category `Gtk.DropDown` (populated from
`/usr/share/ncz-wallpapers/ocs-category-index.json`, filtered to
`usable: true` entries per the design doc's meta-index) + a search
`Gtk.SearchEntry`, above a `Gtk.FlowBox` grid of remote thumbnails.

Data flow:
- On category/search change, call `/usr/local/bin/ncz-wallpaper-ocs`
  (already installed by `45-wallpaper-rotator.sh`, currently a backend with
  presumably no UI caller yet — confirm its CLI surface during
  implementation; if it doesn't yet support category+search listing, that's
  a backend gap this spec surfaces, not something to silently work around in
  Vala) on a background thread, populate the grid with `preview1` thumbnail
  URLs via `Gtk.Picture` + async texture loading (same pattern the existing
  wallpaper grid likely already uses for local thumbnails — reuse, don't
  reinvent).
- Clicking a tile: spawn the import pipeline (fetch → follow redirect →
  sniff real type → normalize/resize → write `pack.json` with
  `origin: "ocs"` and provenance fields, land under
  `~/.local/share/backgrounds/<id>/`, matching the design doc's spec
  verbatim) on a background thread. Show a small spinner overlay on that
  tile during import; on completion, badge it "Added" and ensure "My OCS
  Imports" appears in the source dropdown (create the synthetic
  `.collection` file pointing at that directory if it doesn't exist yet, add
  the new image if it does).
- License/attribution: a small `ⓘ` badge on each tile, hover/tap reveals
  uploader + provider + license-if-stated ("no license stated" when absent,
  per the design doc's confirmed-absent-not-empty finding). This is the only
  UI surface distinguishing an OCS import from a curated pack — no dialog,
  no confirmation step, per the operator's one-click-import decision. The
  badge is what keeps the two tiers visually distinct per the design doc's
  "must never silently acquire the trappings of a curated pack" rule.

### 3. Bing mode

Layout: a `Gtk.FlowBox` of market checkboxes (from
`ncz-wallpaper-bing markets`, e.g. "en-US → United States") above a
chronological `Gtk.FlowBox` history grid (`ncz-wallpaper-bing list --all`,
each entry already carries `thumbnail_path`, `date`, `market`, `caption`,
`pinned`).

- Market checkbox state writes `~/.config/ncz-wallpaper/bing-markets`
  (newline-separated, matching `ncz-wallpaper-bing`'s existing config
  reader) — no new backend needed.
- History tile click: set that image as current immediately (same
  `gsettings set dev.sinty.desktop background-picture-uri` +
  swaybg repaint the rotate script already does — expose it as a small
  standalone command, e.g. `ncz-wallpaper-rotate --pin <path>`, rather than
  duplicating the DE-detection/repaint logic in Vala).
- Pin toggle on each tile calls `ncz-wallpaper-bing pin <market> <date>` /
  `unpin`, already implemented.

### 4. Curated-pack catalog ("Get more artist packs…")

New subsystem — flagged during design review as real added scope, separate
from the mostly-UI-over-shipped-backend work above.

- Catalog source: query ARGOS's internal apt repo
  (`http://192.168.207.22:8081`, per fleet infrastructure) for packages
  matching `ncz-wallpapers-*`. Parse the `Packages` index (name, version,
  description — use the description's first line as display name/artist if
  structured, otherwise fall back to the package name with dashes replaced
  by spaces). This needs a small metadata convention decision during
  implementation: either (a) parse structured fields already in each
  package's `debian/control` Description, or (b) ship a lightweight
  `catalog.json` alongside the repo (simpler to query, doesn't require
  Packages-index parsing) — recommend (b), generated at publish time by
  whatever already builds these packages
  (`build/build-wallpaper-contrib-deb.sh`, referenced in the design doc's
  migration note), listing id/name/artist/preview-thumbnail-url/apt-package-name.
- Display: grid of pack tiles (preview thumbnail, name, artist, an
  "Installed" badge or an "Install" button per tile — check installed state
  via `dpkg-query -W ncz-wallpapers-<id>`).
- Install action: `pkexec apt-get install -y ncz-wallpapers-<id>`, run on a
  background thread, `Gtk.Spinner` overlay on the tile during install.
  `pkexec` matches how `singularity-polkit-agent` (already running per the
  session script) handles other privileged actions in this shell — do not
  invent a second privilege-escalation path.
- On success: re-run collection discovery so the new pack's `.collection`
  file (installed by its own postinst, per the existing pack convention) is
  picked up and the pack becomes selectable in the main source dropdown
  without restarting the shell.
- Failure (network, apt lock held, package not found): inline error text on
  the tile ("couldn't install — try again"), not a modal, matching this
  spec's general error-handling rule below.

### 5. Rotation controls

Unconditionally visible below the source selector (not inside any of the
three stack children — it applies regardless of what's currently browsed).
One `Gtk.Switch` ("Rotate wallpapers") + one interval `Gtk.DropDown"
(preset choices: 10 min / 30 min / 1 hour / 4 hours / 1 day, matching the
daemon's existing 30s-minimum clamp and 600s default). Writes
`~/.config/ncz-wallpaper/rotate-enabled` (`"1"`/`"0"`) and
`rotate-interval` (seconds) — the daemon already re-reads both every cycle,
so no signal/restart is needed from the UI side.

## Data flow summary

```
Desktop page
├── source dropdown ──reads──> collection_dirs() [PR #24] + new Name/Artist parse
│                     ──on select──> populate_grid() [existing] scoped to one Dir
│
├── "Browse Online (OCS)…" ──> OCS browse stack child
│       ├── reads: ocs-category-index.json (installed asset)
│       ├── calls: ncz-wallpaper-ocs list --category <id> --q <search>  [NEW CLI surface — confirm/extend]
│       └── on click: ncz-wallpaper-ocs import <item-id>  [NEW CLI surface — confirm/extend]
│                      writes: ~/.local/share/backgrounds/<id>/{image, pack.json}
│                      writes/updates: ~/.local/share/ncz-wallpapers/collections/ocs-imports.collection
│
├── "Get more artist packs…" ──> catalog browse stack child
│       ├── reads: catalog.json from ARGOS apt repo  [NEW]
│       ├── reads: dpkg-query -W ncz-wallpapers-<id>  (installed state)
│       └── on install: pkexec apt-get install -y ncz-wallpapers-<id>
│
└── rotation switch/interval ──writes──> ~/.config/ncz-wallpaper/{rotate-enabled,rotate-interval}
                                          [already read every cycle by the shipped daemon]
```

## Error handling

Every network- or privilege-dependent action (OCS fetch/import, catalog
fetch/install) degrades to inline, non-blocking feedback in the grid/tile
area — a row of text or a per-tile error state — never a modal dialog. This
matches the rotator's own standing principle ("a mistyped id must not leave
the desktop with no wallpaper at all") extended to the browsing UI: a failed
remote call must not block or freeze the page, and the user must be able to
retry without navigating away.

## Testing

- `collection_dirs()` / `scan_wallpaper_dir()`: already covered by PR #24's
  scope; this spec adds Name/Artist parsing to the same function — extend
  its existing test fixtures (or add unit tests now if none exist yet;
  check before assuming).
- OCS/catalog JSON parsing (category index, catalog.json, OCS list
  response shape) and the pack-import normalization step: pure functions,
  no network, testable against fixture JSON committed alongside the tests.
- The actual HTTP fetch, apt install, and pkexec calls are integration-level
  and not unit-testable in this repo — verify those manually against a real
  ARGOS apt repo entry and a real OCS provider during implementation review,
  the same way PR #24 was verified via a container build rather than a
  meson test target that doesn't exist for this kind of I/O.

## Open questions for implementation (not blocking spec approval)

1. Does `ncz-wallpaper-ocs` already support category+search listing and a
   distinct "import" subcommand, or does it currently only do whatever
   `45-wallpaper-rotator.sh`'s install step wires up? Confirm before writing
   the Vala side — if the CLI surface doesn't exist yet, it needs to be
   built (in `cix-installer`, not `singularity-shell`) as a prerequisite,
   not assumed.
2. `catalog.json` format and where it's generated/published is a decision
   for `build/build-wallpaper-contrib-deb.sh` (cix-installer), not this
   repo — this spec only consumes it.
3. Confirm the existing `desktop_page.vala` widget conventions (Gtk.Stack
   vs. something else already used for switching page content) before
   introducing a new pattern — match what's there.
