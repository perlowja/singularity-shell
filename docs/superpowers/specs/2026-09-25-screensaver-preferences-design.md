# Screensaver preferences + idle/lock integration — design

**Date:** 2026-09-25
**Scope:** singularity-shell (compositor + settings UI) + ncz-screensavers
(hack binaries + per-hack config schemas). Architectural: new Wayland
protocol usage, a new daemon, a new settings surface, touches the existing
lock-screen security path.

## Goal

NCZ-OS ships ~141 GLES3 screensaver hacks (`ncz-screensavers`). Nothing
currently launches them, times them out, or stops them on user input.
Build the missing pieces so idle → screensaver → activity → lock screen
works end to end, with a preferences UI roughly equivalent to
`xscreensaver-demo`: pick random-vs-specific hack, configure per-hack
parameters, set idle timeout, set the default (black hole).

## What already exists (do not rebuild)

- `ext-session-lock-v1` protocol + `lock_screen.vala` + `lock_surface.c/h`
  + gschema + PAM module, in `src/lockscreen/`. This is the real, working
  lock UI. The new work only needs to INVOKE it, not reimplement it.
- 141 built `*_gles3` hack binaries in ncz-screensavers, each already
  configurable via X-resource-style `DEFAULTS` strings (e.g. squirtorus's
  `*starColor: #FFD166`) parsed at hack startup via `get_string_resource`/
  `parse_color`.

## What's missing (this design's scope)

### 1. Idle detection — `ext-idle-notify-v1`

Not present anywhere in singularity-shell. Wire it into the compositor
core (`src/core/`, alongside `system_components.vala`): create an idle
notification with the configured timeout, and connect its `idled`/
`resumed` signals to the launcher daemon below. This piece is generic
(any distro wants idle detection) — **contribute upstream**, on the
`fork` remote, per contribution rule: no NCZ-specific naming or paths in
this layer.

### 2. Screensaver launcher daemon

A small new component (`src/core/screensaver_manager.vala`, generic
naming, no `ncz-` prefix per contribution rules) that:
- On `idled`: reads the active config (mode = off / random / specific
  hack; hack list; per-hack args), spawns the chosen hack binary
  fullscreen on a dedicated layer-shell surface (background layer, below
  lock).
- On `resumed` (any key/mouse activity): kills the running hack
  immediately, then invokes the EXISTING `ext-session-lock-v1` client
  (`lock_screen.vala`'s entry point) to show the real lock screen. This
  is the literal "activity interrupts screensaver → lock screen" behavior
  requested.
- Config storage: a GSettings schema (`dev.sinty.screensaver`, matching
  the existing `dev.sinty.lockscreen` naming convention) holding mode,
  hack list/selection, idle-timeout-seconds, and per-hack argument
  overrides (as a serialized dict keyed by hack id).
- **Mode is 4-way, not 2-way**: `off` / `random-all` (any verified hack) /
  `random-category` (any verified hack within a chosen theme) /
  `specific` (one exact hack). Category comes from the existing
  `hacks.tsv` taxonomy (140 hacks already classified across 7 themes:
  Nature & Organic, Abstract & Psychedelic, Geometry & Fractals, Machines
  & Objects, Particles & Physics, Space & Sci-Fi, Text & Data — plus the
  new black-hole hack, uncategorized in that file as of this writing,
  needs a theme, e.g. a new "Space & Sci-Fi" entry or its own).
- This component is generic mechanism — **upstream-appropriate** — but
  its DEFAULT config (which hacks exist, black hole as default) is
  NCZ-specific DATA, not code, so it stays clean: ship a generic empty/
  built-in-hack-free default upstream, and NCZ-OS's own dconf
  override/packaging (downstream, in cix-installer or a ncz-screensavers
  packaging step) sets the real default list + black hole as default,
  per contribution rule 2 (no NCZ leakage into generic code).

### 3. Per-hack settings schema (the xscreensaver-demo equivalent mechanism)

Real xscreensaver does NOT hand-build a settings dialog per hack — each
hack ships a small XML file (`/usr/share/xscreensaver/config/<hack>.xml`)
declaring its command-line options as typed widgets (slider, checkbox,
option-menu), and `xscreensaver-demo` has ONE generic renderer that reads
any hack's XML and builds its dialog. Replicate this, adapted to our
hacks' existing X-resource `DEFAULTS` convention:

- New, small schema format (JSON or XML, JSON is simpler for Vala's
  `Json.Parser`) per hack, shipped BY ncz-screensavers (downstream,
  NCZ-specific data) at `share/ncz-screensavers/config/<hack>.json`:
  ```json
  {
    "label": "Squirtorus",
    "binary": "squirtorus_gles3",
    "options": [
      {"resource": "starColor", "type": "color", "label": "Star color", "default": "#FFD166"},
      {"resource": "groundColor", "type": "color", "label": "Ground color", "default": "#E85D75"}
    ]
  }
  ```
- ONE generic Vala renderer in singularity-shell (upstream-appropriate,
  generic: "read a JSON options schema, build a dialog, write results
  back as command-line args when launching the target binary") — this
  mirrors xscreensaver-demo's actual architecture and avoids hand-writing
  141 dialogs.
- Not every hack needs a schema file on day one — a hack with no schema
  just gets no "Settings..." button (matches real xscreensaver's
  behavior for hacks with no config).

### 4. Preferences window

A new top-level settings surface (not a sidebar page — this is a
dedicated window, matching xscreensaver-demo's own shape, and matching
contribution rule 5's "gate new UI on a real shipped backend" — this
window only renders once the launcher daemon + schema loader above are
real):
- Left: scrollable list of available hacks (label + a thumbnail).
  **Open design question, flag explicitly, do not silently pick an
  answer**: real xscreensaver-demo embeds a LIVE running preview per
  selected hack via X11 window reparenting — Wayland's security model
  makes live foreign-surface embedding hard/impossible without a
  dedicated preview protocol. Simplest viable alternative: a static
  thumbnail per hack (pre-rendered once, shipped as an image asset
  alongside each hack's schema file, refreshed manually when a hack's
  visuals change) rather than a live embed. Confirm this trade-off is
  acceptable before implementing rather than assuming.
- Right: mode selector (Off / Random from list / Selected hack), idle
  timeout slider, "Settings..." button (opens the generic per-hack
  dialog from section 3) for the currently-highlighted hack, "Set as
  default" action.
- Reachable from the existing sidebar's desktop or a new dedicated page
  entry, following the existing `desktop_page.vala`-style pattern for
  navigation only — the window itself is standalone.

## Catalog gate — verified-working hacks only

The picker must NOT simply enumerate every binary that compiles. Real,
measured this session: an automated pixel-diff PASS does not prove visual
correctness — `squirtorus_gles3` and `razzledazzle_gles3` both PASS the
animation-diff matrix while shipping real color bugs (stars render pure
black instead of gold; hull renders near-grayscale instead of high-chroma)
confirmed on two separate GPU vendors. A catalog built from "compiles and
animates" would ship known-broken/subpar hacks as if they were fine.

`hacks.tsv` (downstream, ncz-screensavers) gets a 5th column, `verified`,
with three real states:
- `pass` — animated matrix PASS AND a human has visually confirmed the
  actual output matches intent (not just "isn't black/static").
- `needs-work` — known issue (wrong colors, missing texture, confirmed
  broken), tracked with a reason. Excluded from the shipped catalog.
- `untested` — default for anything not yet through visual QA. Also
  excluded from the shipped catalog until promoted to `pass` — the
  catalog defaults to the SMALLER, verified-correct set, not the larger
  unverified one.

The preferences window (and the launcher's random-selection pools) only
ever draw from `verified=pass` rows. This is a living list, updated as
fixes land and get re-verified (e.g. once the in-flight squirtorus/
razzledazzle color fix is confirmed with real pixel sampling against the
intended hex values, flip those two rows to `pass`).

## Repo / contribution split (per `singularity-contribution-guidelines.md`)

| Piece | Repo | Upstream or downstream |
|---|---|---|
| `ext-idle-notify-v1` wiring | singularity-shell | Upstream (fork → PR) |
| `screensaver_manager.vala` (generic launcher/kill/lock-invoke) | singularity-shell | Upstream (fork → PR) |
| Generic per-hack JSON-schema settings renderer + preferences window | singularity-shell | Upstream (fork → PR) |
| Per-hack `.json` schema + thumbnail assets | ncz-screensavers | Downstream, NCZ-owned |
| Default hack list + black-hole-as-default config | cix-installer packaging / dconf override | Downstream, NCZ-owned |

No `Adw.*` widgets (rule 1) — use existing `libsingularity` equivalents
throughout the new preferences window and dialog, matching
`desktop_page.vala`'s existing widget choices. AI-attribution trailers
per rule 0 on every commit to the fork.

## Verification

- Real idle→launch→activity→lock cycle on real hardware (PEGASUS or
  MEDUSA, both already have working ncz-screensavers builds), with the
  actual `ext-session-lock-v1` lock screen appearing after simulated
  input, not just a log line saying it would have.
- Generic schema renderer tested against at least 3 real hacks with
  different option shapes (squirtorus's colors, blackhole's numeric
  sliders if exposed, a hack with no schema at all to confirm graceful
  no-Settings-button behavior).
- No libadwaita, no NCZ-specific strings/paths in the singularity-shell
  side — grep clean before any fork PR, per rule 1 and rule 2.
