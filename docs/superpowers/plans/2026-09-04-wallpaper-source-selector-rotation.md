# Wallpaper Source Selector + Rotation Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user switch which installed wallpaper collection (pack, NCZ default, Bing) the Desktop page's grid shows, and control rotation on/off + interval, all from the Desktop settings page.

**Architecture:** Extract the `.collection` KeyFile registry parsing (currently a private, dir-only helper inside `desktop_page.vala`) into a standalone, unit-testable core class that also reads `Name`/`Artist`. Add a second core class for reading/writing the plain-text state files the shipped `ncz-wallpaper-rotate`/`ncz-wallpaper-daemon` scripts already read every cycle (`~/.config/ncz-wallpaper/{collection,rotate-enabled,rotate-interval}`) — no daemon change, no new IPC, the UI and the daemon just share the same files. Wire both into `desktop_page.vala` as two new rows above/below the existing wallpaper grid, and scope `populate_grid()`'s scan to the one selected collection's directory instead of the current combined everything-at-once scan.

**Tech Stack:** Vala, GTK4, GLib (KeyFile, Settings), Gee collections, libsingularity widgets (`Singularity.Widgets.SelectionRow`, `SwitchRow`, `PreferencesGroup`, `PreferencesRow`), meson/ninja, GLib.Test.

**Spec:** `docs/superpowers/specs/2026-09-04-wallpaper-pack-browser-ocs-design.md` — this plan implements spec sections 1 ("Source selector") and 5 ("Rotation controls") only. Sections 2-4 (OCS, Bing history, curated-pack catalog) are separate plans.

**Branch:** branch from `fix/wallpaper-picker-pack-registry` (PR #24 — the recursive collection scan this plan builds on top of; not yet merged upstream). Do not branch from `main`, the collection registry this plan extends does not exist there yet.

## Global Constraints

- No change to the rotator daemon (`cix-installer/post-install/45-wallpaper-rotator.sh`'s `ncz-wallpaper-rotate` / `ncz-wallpaper-daemon`). The UI reads/writes the exact same three files the daemon already polls every cycle — never invent a new config path or IPC mechanism.
- `.collection` (GLib.KeyFile, INI-shaped) stays the on-disk format read here. Do not add `.pack.json` parsing in this plan — that migration is explicitly out of scope per the spec.
- Match existing file/test conventions exactly: a pure-logic class goes in `src/core/<name>.vala`, its GLib.Test suite in `tests/<name>_test.vala`, wired into `meson.build` as `executable('<name>-test', sources: ['src/core/<name>.vala', 'tests/<name>_test.vala'], dependencies: [dependency('gobject-2.0'), gee_dep])` + `test('<name>', <name>_test)` — copy the `bar_layout`/`bar-layout-test` block in `meson.build` verbatim as the template.
- GTK/Vala integration changes (anything touching `desktop_page.vala`) are verified by a real container build (`meson compile -C build`, confirm `singularity-desktop` links), not by a meson `test()` target — this codebase has no GTK-widget test harness, don't invent one.
- No AI-attribution footer in code comments (this plan's own commits get the standard trailer per this session's attribution rule, but nothing about the *code* mentions Claude/AI).

---

### Task 1: Wallpaper collection registry (id/name/artist/dir/type)

**Files:**
- Create: `src/core/wallpaper_collections.vala`
- Test: `tests/wallpaper_collections_test.vala`
- Modify: `meson.build` (add the test executable + test() call, following the `bar_layout_test` block)

**Interfaces:**
- Consumes: nothing new — reads `.collection` KeyFiles from directories passed in explicitly (no `GLib.Environment` calls inside the testable class; the caller passes real search roots so tests can point it at a temp dir).
- Produces: `Singularity.WallpaperCollectionInfo` (public fields: `string id`, `string name`, `string artist`, `string dir`, `string type`) and `Singularity.WallpaperCollections.parse(string[] search_roots) -> Gee.ArrayList<WallpaperCollectionInfo>`. Task 3 calls `WallpaperCollections.parse(...)` in place of `desktop_page.vala`'s current private `collection_dirs()`.

- [ ] **Step 1: Write the failing test**

Create `tests/wallpaper_collections_test.vala`:

```vala
using GLib;
using Gee;
using Singularity;

private string make_tmp_dir() {
    string path = GLib.DirUtils.make_tmp("wpcollections-XXXXXX");
    return path;
}

private void write_collection(string dir, string filename, string contents) {
    string path = GLib.Path.build_filename(dir, filename);
    try {
        FileUtils.set_contents(path, contents);
    } catch (Error e) {
        error("test setup failed: %s", e.message);
    }
}

private void test_parses_id_name_artist_dir() {
    string root = make_tmp_dir();
    write_collection(root, "brandon.collection",
        "[Collection]\n" +
        "Id=brandon-perlow\n" +
        "Name=Brandon Perlow\n" +
        "Artist=Brandon Perlow\n" +
        "Type=static\n" +
        "Dir=/usr/share/backgrounds/ncz/brandon-perlow\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "brandon-perlow");
    assert(result[0].name == "Brandon Perlow");
    assert(result[0].artist == "Brandon Perlow");
    assert(result[0].dir == "/usr/share/backgrounds/ncz/brandon-perlow");
    assert(result[0].type == "static");
}

private void test_id_falls_back_to_filename_stem() {
    string root = make_tmp_dir();
    write_collection(root, "ncz.collection",
        "[Collection]\n" +
        "Name=NCZ-OS\n" +
        "Dir=/usr/share/backgrounds/ncz\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "ncz");
}

private void test_skips_dir_less_collection() {
    string root = make_tmp_dir();
    write_collection(root, "broken.collection",
        "[Collection]\n" +
        "Id=broken\n" +
        "Name=Broken\n");
    write_collection(root, "good.collection",
        "[Collection]\n" +
        "Id=good\n" +
        "Name=Good\n" +
        "Dir=/some/dir\n");

    var result = WallpaperCollections.parse({ root });

    assert(result.size == 1);
    assert(result[0].id == "good");
}

private void test_ignores_non_collection_files_and_missing_dirs() {
    string root = make_tmp_dir();
    write_collection(root, "notes.txt", "not a collection\n");

    var result = WallpaperCollections.parse({ root, "/definitely/does/not/exist" });

    assert(result.size == 0);
}

private void test_dedupes_by_id_first_root_wins() {
    string root_a = make_tmp_dir();
    string root_b = make_tmp_dir();
    write_collection(root_a, "ncz.collection",
        "[Collection]\nId=ncz\nName=System\nDir=/system/ncz\n");
    write_collection(root_b, "ncz.collection",
        "[Collection]\nId=ncz\nName=User Override\nDir=/user/ncz\n");

    var result = WallpaperCollections.parse({ root_a, root_b });

    assert(result.size == 1);
    assert(result[0].name == "System");
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-collections/parses-id-name-artist-dir", test_parses_id_name_artist_dir);
    Test.add_func("/wallpaper-collections/id-falls-back-to-filename-stem", test_id_falls_back_to_filename_stem);
    Test.add_func("/wallpaper-collections/skips-dir-less-collection", test_skips_dir_less_collection);
    Test.add_func("/wallpaper-collections/ignores-non-collection-files-and-missing-dirs", test_ignores_non_collection_files_and_missing_dirs);
    Test.add_func("/wallpaper-collections/dedupes-by-id-first-root-wins", test_dedupes_by_id_first_root_wins);
    return Test.run();
}
```

Add to `meson.build`, directly after the existing `bar_layout_test` block (copy its shape exactly):

```meson
wallpaper_collections_test = executable('wallpaper-collections-test',
  sources: ['src/core/wallpaper_collections.vala', 'tests/wallpaper_collections_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0'), gee_dep],
)
test('wallpaper-collections', wallpaper_collections_test)
```

- [ ] **Step 2: Run test to verify it fails**

Run (inside the project's container build environment, per PR #24's established build path — do not attempt this on the bare host, `libgtk4-layer-shell-dev` conflicts with the NCZ-patched runtime lib exactly as documented for the main build):

```
meson setup build   # if not already configured
meson test -C build wallpaper-collections -v
```

Expected: FAIL at compile time — `src/core/wallpaper_collections.vala` does not exist yet, `error: The following configuration option(s) failed` / a Vala "unknown namespace member `WallpaperCollections`" or a meson "File does not exist" error. Any compile failure referencing the missing file/symbol counts as the expected failure.

- [ ] **Step 3: Write minimal implementation**

Create `src/core/wallpaper_collections.vala`:

```vala
using GLib;
using Gee;

namespace Singularity {

    public class WallpaperCollectionInfo : Object {
        public string id { get; private set; }
        public string name { get; private set; }
        public string artist { get; private set; }
        public string dir { get; private set; }
        public string type { get; private set; }

        public WallpaperCollectionInfo(string id, string name, string artist, string dir, string type) {
            this.id = id;
            this.name = name;
            this.artist = artist;
            this.dir = dir;
            this.type = type;
        }
    }

    // Parses the .collection registry (INI-shaped KeyFiles, one per pack or
    // provider) into a list of WallpaperCollectionInfo, in the priority order
    // the search roots are given -- a later root's file for the same Id is
    // ignored, matching "first root wins" so callers pass roots most-specific
    // (e.g. per-user) LAST if they want a user override to win, or FIRST if
    // they want the shipped default to win. desktop_page.vala's caller passes
    // system dirs then the user dir, so a user's own collection can override
    // one bundled with the OS.
    //
    // Callers pass explicit search_roots (not read from GLib.Environment
    // here) so this class stays testable against a temp directory with no
    // real filesystem layout assumptions.
    public class WallpaperCollections : Object {
        public static Gee.ArrayList<WallpaperCollectionInfo> parse(string[] search_roots) {
            var results = new Gee.ArrayList<WallpaperCollectionInfo>();
            var seen_ids = new Gee.HashSet<string>();

            foreach (string root in search_roots) {
                try {
                    var dir = File.new_for_path(root);
                    if (!dir.query_exists()) continue;
                    var en = dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                    FileInfo info;
                    while ((info = en.next_file(null)) != null) {
                        string filename = info.get_name();
                        if (!filename.has_suffix(".collection")) continue;

                        var kf = new GLib.KeyFile();
                        try {
                            kf.load_from_file(GLib.Path.build_filename(root, filename), GLib.KeyFileFlags.NONE);
                        } catch (Error e) {
                            continue; // malformed file, skip it
                        }

                        string collection_dir;
                        try {
                            collection_dir = kf.get_string("Collection", "Dir");
                        } catch (Error e) {
                            continue; // Dir-less collection, skip it
                        }
                        if (collection_dir == null || collection_dir == "") continue;

                        string id;
                        try {
                            id = kf.get_string("Collection", "Id");
                        } catch (Error e) {
                            id = filename.substring(0, filename.length - ".collection".length);
                        }
                        if (id == null || id == "") {
                            id = filename.substring(0, filename.length - ".collection".length);
                        }
                        if (!seen_ids.add(id)) continue; // first root wins

                        string name;
                        try { name = kf.get_string("Collection", "Name"); }
                        catch (Error e) { name = id; }

                        string artist;
                        try { artist = kf.get_string("Collection", "Artist"); }
                        catch (Error e) { artist = ""; }

                        string type;
                        try { type = kf.get_string("Collection", "Type"); }
                        catch (Error e) { type = "static"; }

                        results.add(new WallpaperCollectionInfo(id, name, artist, collection_dir, type));
                    }
                } catch (Error e) {
                    continue;
                }
            }
            return results;
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```
meson compile -C build
meson test -C build wallpaper-collections -v
```

Expected: PASS, all 5 test cases green.

- [ ] **Step 5: Commit**

```bash
git add src/core/wallpaper_collections.vala tests/wallpaper_collections_test.vala meson.build
git commit -m "feat(wallpaper): extract collection registry parsing into a testable core class"
```

---

### Task 2: Rotation/selection state file helpers

**Files:**
- Create: `src/core/wallpaper_rotation_state.vala`
- Test: `tests/wallpaper_rotation_state_test.vala`
- Modify: `meson.build` (add the test executable + test() call)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Singularity.WallpaperRotationState`, a class taking a `config_dir` (the directory equivalent to `~/.config/ncz-wallpaper`, injected so tests use a temp dir instead of the real `$HOME`) with methods: `get_selected_collection(string default_id) -> string`, `set_selected_collection(string id)`, `get_rotate_enabled() -> bool`, `set_rotate_enabled(bool)`, `get_rotate_interval_seconds() -> int`, `set_rotate_interval_seconds(int)`. Task 3 uses `get_selected_collection`/`set_selected_collection`; Task 4 uses the other four.

- [ ] **Step 1: Write the failing test**

Create `tests/wallpaper_rotation_state_test.vala`:

```vala
using GLib;
using Singularity;

private string make_tmp_dir() {
    return GLib.DirUtils.make_tmp("wprotation-XXXXXX");
}

private void test_selected_collection_defaults_when_unset() {
    var state = new WallpaperRotationState(make_tmp_dir());
    assert(state.get_selected_collection("ncz") == "ncz");
}

private void test_selected_collection_roundtrips() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_selected_collection("brandon-perlow");
    assert(state.get_selected_collection("ncz") == "brandon-perlow");
}

private void test_selected_collection_strips_whitespace() {
    string dir = make_tmp_dir();
    try {
        FileUtils.set_contents(GLib.Path.build_filename(dir, "collection"), " bing \n");
    } catch (Error e) { error("test setup failed: %s", e.message); }
    var state = new WallpaperRotationState(dir);
    assert(state.get_selected_collection("ncz") == "bing");
}

private void test_rotate_enabled_defaults_true() {
    var state = new WallpaperRotationState(make_tmp_dir());
    assert(state.get_rotate_enabled() == true);
}

private void test_rotate_enabled_roundtrips_false() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_rotate_enabled(false);
    assert(state.get_rotate_enabled() == false);
    state.set_rotate_enabled(true);
    assert(state.get_rotate_enabled() == true);
}

private void test_rotate_interval_defaults_to_600() {
    var state = new WallpaperRotationState(make_tmp_dir());
    assert(state.get_rotate_interval_seconds() == 600);
}

private void test_rotate_interval_roundtrips() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_rotate_interval_seconds(1800);
    assert(state.get_rotate_interval_seconds() == 1800);
}

private void test_rotate_interval_clamps_to_30_minimum() {
    var state = new WallpaperRotationState(make_tmp_dir());
    state.set_rotate_interval_seconds(5);
    assert(state.get_rotate_interval_seconds() == 30);
}

private void test_rotate_interval_garbage_on_disk_reads_as_default() {
    string dir = make_tmp_dir();
    try {
        FileUtils.set_contents(GLib.Path.build_filename(dir, "rotate-interval"), "not-a-number\n");
    } catch (Error e) { error("test setup failed: %s", e.message); }
    var state = new WallpaperRotationState(dir);
    assert(state.get_rotate_interval_seconds() == 600);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-rotation-state/selected-collection-defaults-when-unset", test_selected_collection_defaults_when_unset);
    Test.add_func("/wallpaper-rotation-state/selected-collection-roundtrips", test_selected_collection_roundtrips);
    Test.add_func("/wallpaper-rotation-state/selected-collection-strips-whitespace", test_selected_collection_strips_whitespace);
    Test.add_func("/wallpaper-rotation-state/rotate-enabled-defaults-true", test_rotate_enabled_defaults_true);
    Test.add_func("/wallpaper-rotation-state/rotate-enabled-roundtrips-false", test_rotate_enabled_roundtrips_false);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-defaults-to-600", test_rotate_interval_defaults_to_600);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-roundtrips", test_rotate_interval_roundtrips);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-clamps-to-30-minimum", test_rotate_interval_clamps_to_30_minimum);
    Test.add_func("/wallpaper-rotation-state/rotate-interval-garbage-on-disk-reads-as-default", test_rotate_interval_garbage_on_disk_reads_as_default);
    return Test.run();
}
```

Add to `meson.build` after Task 1's block:

```meson
wallpaper_rotation_state_test = executable('wallpaper-rotation-state-test',
  sources: ['src/core/wallpaper_rotation_state.vala', 'tests/wallpaper_rotation_state_test.vala'],
  dependencies: [dependency('gobject-2.0'), dependency('glib-2.0'), dependency('gio-2.0')],
)
test('wallpaper-rotation-state', wallpaper_rotation_state_test)
```

- [ ] **Step 2: Run test to verify it fails**

```
meson test -C build wallpaper-rotation-state -v
```

Expected: FAIL — `src/core/wallpaper_rotation_state.vala` does not exist, compile error.

- [ ] **Step 3: Write minimal implementation**

Create `src/core/wallpaper_rotation_state.vala`. Values mirror exactly what `cix-installer/post-install/45-wallpaper-rotator.sh`'s shipped `ncz-wallpaper-rotate`/`ncz-wallpaper-daemon` scripts already read: default interval 600s, 30s floor, `rotate-enabled` file holding `"0"` to disable (anything else, including absence, means enabled), `collection` file holding the current collection id (absence means "ncz"):

```vala
using GLib;

namespace Singularity {

    // Reads and writes the plain-text state files
    // cix-installer/post-install/45-wallpaper-rotator.sh's ncz-wallpaper-rotate
    // and ncz-wallpaper-daemon shell scripts already poll every rotation cycle
    // -- this class is the UI's side of that same shared state, not a new
    // mechanism. config_dir is injected (rather than read from
    // GLib.Environment here) so it's testable against a temp directory.
    public class WallpaperRotationState : Object {
        private const int DEFAULT_INTERVAL_SECONDS = 600;
        private const int MIN_INTERVAL_SECONDS = 30;

        private string config_dir;

        public WallpaperRotationState(string config_dir) {
            this.config_dir = config_dir;
        }

        private string path_for(string filename) {
            return GLib.Path.build_filename(config_dir, filename);
        }

        private string? read_trimmed(string filename) {
            string path = path_for(filename);
            if (!FileUtils.test(path, FileTest.EXISTS)) return null;
            string contents;
            try {
                FileUtils.get_contents(path, out contents);
            } catch (Error e) {
                return null;
            }
            return contents.strip();
        }

        private void write(string filename, string contents) {
            GLib.DirUtils.create_with_parents(config_dir, 0700);
            try {
                FileUtils.set_contents(path_for(filename), contents);
            } catch (Error e) {
                warning("wallpaper rotation state: could not write %s: %s", filename, e.message);
            }
        }

        public string get_selected_collection(string default_id) {
            string? value = read_trimmed("collection");
            return (value == null || value == "") ? default_id : value;
        }

        public void set_selected_collection(string id) {
            write("collection", id);
        }

        public bool get_rotate_enabled() {
            string? value = read_trimmed("rotate-enabled");
            return value != "0";
        }

        public void set_rotate_enabled(bool enabled) {
            write("rotate-enabled", enabled ? "1" : "0");
        }

        public int get_rotate_interval_seconds() {
            string? value = read_trimmed("rotate-interval");
            if (value == null) return DEFAULT_INTERVAL_SECONDS;
            int64 parsed;
            if (!int64.try_parse(value, out parsed)) return DEFAULT_INTERVAL_SECONDS;
            int seconds = (int) parsed;
            return seconds < MIN_INTERVAL_SECONDS ? MIN_INTERVAL_SECONDS : seconds;
        }

        public void set_rotate_interval_seconds(int seconds) {
            int clamped = seconds < MIN_INTERVAL_SECONDS ? MIN_INTERVAL_SECONDS : seconds;
            write("rotate-interval", clamped.to_string());
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```
meson compile -C build
meson test -C build wallpaper-rotation-state -v
```

Expected: PASS, all 9 test cases green.

- [ ] **Step 5: Commit**

```bash
git add src/core/wallpaper_rotation_state.vala tests/wallpaper_rotation_state_test.vala meson.build
git commit -m "feat(wallpaper): add rotation/selection state file helpers shared with the rotator daemon"
```

---

### Task 3: Source selector row, scoped grid scan

**Files:**
- Modify: `src/components/sidebar/pages/desktop_page.vala:33` (add a field), `:146-165` (insert the selector row), `:1812-1843` (remove the now-superseded `collection_dirs()`), `:1915-1961` (`populate_grid()` — scope the scan to the selected collection)

**Interfaces:**
- Consumes: `Singularity.WallpaperCollections.parse(string[]) -> Gee.ArrayList<WallpaperCollectionInfo>` (Task 1); `Singularity.WallpaperRotationState.get_selected_collection(string) -> string` / `.set_selected_collection(string)` (Task 2, constructed with `GLib.Path.build_filename(GLib.Environment.get_user_config_dir(), "ncz-wallpaper")`).
- Produces: `populate_grid()`'s new signature/behavior — still `private void populate_grid()`, no callers outside this file change, but it now scans only `selected_collection.dir` instead of the combined backgrounds-paths-plus-every-collection list.

- [ ] **Step 1: Add the field and rotation-state instance**

In `desktop_page.vala`, right after the existing field `private FlowBox wallpaper_grid;` (line 33), add:

```vala
        private FlowBox wallpaper_grid;
        private Gee.ArrayList<WallpaperCollectionInfo> wallpaper_collections = new Gee.ArrayList<WallpaperCollectionInfo>();
        private WallpaperRotationState rotation_state = new WallpaperRotationState(
            GLib.Path.build_filename(GLib.Environment.get_user_config_dir(), "ncz-wallpaper"));
```

- [ ] **Step 2: Replace `collection_dirs()` with a call into the new registry**

Delete lines 1800-1843 (the doc comment and the whole `collection_dirs()` method body, from `// Directories declared by installed wallpaper packs.` through its closing `}`). It's fully superseded by `WallpaperCollections.parse()` from Task 1.

- [ ] **Step 3: Replace the grid-group construction block with one that also builds the collection list and the source-selector row**

Replace the entire existing block from `var grid_group = new PreferencesGroup(_("Wallpapers"));` through `add_group(grid_group);` (currently lines 146-164) with:

```vala
            var grid_group = new PreferencesGroup(_("Wallpapers"));

            var collection_roots = new Gee.ArrayList<string>();
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                collection_roots.add(GLib.Path.build_filename(d, "ncz-wallpapers", "collections"));
            collection_roots.add(GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "ncz-wallpapers", "collections"));
            wallpaper_collections = WallpaperCollections.parse(collection_roots.to_array());

            var source_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (var collection in wallpaper_collections) {
                string label = (collection.artist != null && collection.artist != "" && collection.artist != collection.name)
                    ? "%s — %s".printf(collection.name, collection.artist)
                    : collection.name;
                source_options.add(new Singularity.Core.AppSettingOption() {
                    id = collection.id, label = label
                });
            }
            string initial_collection_id = rotation_state.get_selected_collection("ncz");
            bool have_initial = false;
            foreach (var opt in source_options) if (opt.id == initial_collection_id) have_initial = true;
            if (!have_initial && source_options.size > 0) initial_collection_id = source_options[0].id;

            var source_row = new SelectionRow.with_options(
                _("Wallpaper Source"), source_options, initial_collection_id);
            source_row.subtitle = _("Which installed collection the gallery below shows");
            source_row.selected.connect((id) => {
                rotation_state.set_selected_collection(id);
                populate_grid();
            });
            grid_group.add_row(source_row);

            wallpaper_grid = new FlowBox();
            wallpaper_grid.add_css_class("wallpaper-gallery");
            wallpaper_grid.valign = Align.START;
            wallpaper_grid.halign = Align.FILL;
            wallpaper_grid.hexpand = true;
            wallpaper_grid.max_children_per_line = 2;
            wallpaper_grid.min_children_per_line = 2; // always two columns; the sidebar is sized for it
            wallpaper_grid.selection_mode = SelectionMode.NONE;
            wallpaper_grid.column_spacing = 14;
            wallpaper_grid.row_spacing = 14;
            wallpaper_grid.margin_top = 10;
            wallpaper_grid.margin_bottom = 10;
            wallpaper_grid.margin_start = 10;
            wallpaper_grid.margin_end = 10;
            var grid_row = new PreferencesRow();
            grid_row.set_child(wallpaper_grid);
            grid_group.add_row(grid_row);
            add_group(grid_group);
```

This is the same `wallpaper_grid`/`grid_row` construction as before, unchanged, just preceded by the new collection-loading and source-row code and with `grid_group`'s creation moved to the top of the block so `source_row` can be added to it before `grid_row` is. The line after this block, `GLib.Idle.add(() => { populate_grid(); return GLib.Source.REMOVE; });`, stays exactly where it already is — untouched.

- [ ] **Step 4: Scope `populate_grid()` to the selected collection**

Replace the body of `populate_grid()` (currently lines 1915-1961). The "recent" handling at the top is unconditional and untouched (cross-cutting, independent of collection); only the scan-path construction changes from "every backgrounds path plus every collection dir" to "just the selected collection's dir":

```vala
        private void populate_grid() {
            int gen = ++wallpaper_grid_generation;
            wallpaper_grid.remove_all();
            var uris = new ArrayList<string>();
            string[] recent = settings.get_strv("recent-wallpapers");
            foreach (string uri in recent) {
                if (!uris.contains(uri)) {
                    uris.add(uri);
                    add_wallpaper_card(uri, true);
                }
            }

            var seen = new HashSet<string>();
            foreach (string uri in recent) seen.add(uri);

            string selected_id = rotation_state.get_selected_collection("ncz");
            string? scan_dir = null;
            foreach (var collection in wallpaper_collections) {
                if (collection.id == selected_id) { scan_dir = collection.dir; break; }
            }
            // A selection with no matching collection (deleted pack, stale
            // state file) must not empty the grid silently -- fall back to
            // whatever the first known collection is, same "never leave the
            // desktop with no wallpaper" principle the rotator script itself
            // follows.
            if (scan_dir == null && wallpaper_collections.size > 0) {
                scan_dir = wallpaper_collections[0].dir;
            }

            string[] scan_paths = (scan_dir == null) ? new string[0] : new string[] { scan_dir };
            new GLib.Thread<void>("wallpaper-scan", () => {
                var candidates = new ArrayList<WallpaperCandidate>();
                var thread_seen = new HashSet<string>();
                foreach (string uri in seen) thread_seen.add(uri);

                var visited_dirs = new HashSet<string>();
                foreach (string path in scan_paths)
                    scan_wallpaper_dir(path, candidates, thread_seen, visited_dirs, 0);

                GLib.Idle.add(() => {
                    if (gen != wallpaper_grid_generation) return GLib.Source.REMOVE;
                    append_wallpaper_candidates(candidates, gen, 0);
                    return GLib.Source.REMOVE;
                });
            });
        }
```

- [ ] **Step 5: Build and verify**

This is a GTK/Vala integration change with no meson `test()` coverage (per this codebase's convention — GTK widgets aren't unit-tested here, only pure-logic core classes are). Verify via a real container build, same as PR #24 and its follow-up fix:

```
meson setup --reconfigure build
meson compile -C build
```

Expected: exit 0, `[N/N] Linking target singularity-desktop`. Also re-run the full test suite to confirm nothing regressed:

```
meson test -C build -v
```

Expected: all tests pass, including the two new suites from Tasks 1-2.

Manual verification (on real hardware or the O6N/cixmini test path already used for this project — not fabricated, actually run): launch `singularity-desktop`, open Desktop settings, confirm the Wallpaper Source row lists every installed `.collection` (at minimum "NCZ-OS" and "Bing Image of the Day" on a stock install), and that switching it repopulates the grid with only that collection's images.

- [ ] **Step 6: Commit**

```bash
git add src/components/sidebar/pages/desktop_page.vala
git commit -m "feat(wallpaper): add a source selector, scope the grid to one collection"
```

---

### Task 4: Rotation on/off + interval row

**Files:**
- Modify: `src/components/sidebar/pages/desktop_page.vala` (add two rows to `grid_group`, after `grid_row`)

**Interfaces:**
- Consumes: `Singularity.WallpaperRotationState.get_rotate_enabled/set_rotate_enabled/get_rotate_interval_seconds/set_rotate_interval_seconds` (Task 2), via the `rotation_state` field Task 3 already added.
- Produces: nothing consumed elsewhere — this is the final row in this plan's UI.

- [ ] **Step 1: Add the rotation switch + interval rows**

Immediately after `grid_group.add_row(grid_row);` (from Task 3's step 4), before `add_group(grid_group);`, insert:

```vala
            var rotate_row = new SwitchRow(_("Rotate Wallpapers"),
                _("Automatically change the wallpaper on a timer"),
                rotation_state.get_rotate_enabled());
            grid_group.add_row(rotate_row);

            var interval_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            interval_options.add(new Singularity.Core.AppSettingOption() { id = "600", label = _("Every 10 minutes") });
            interval_options.add(new Singularity.Core.AppSettingOption() { id = "1800", label = _("Every 30 minutes") });
            interval_options.add(new Singularity.Core.AppSettingOption() { id = "3600", label = _("Every hour") });
            interval_options.add(new Singularity.Core.AppSettingOption() { id = "14400", label = _("Every 4 hours") });
            interval_options.add(new Singularity.Core.AppSettingOption() { id = "86400", label = _("Every day") });

            int current_interval = rotation_state.get_rotate_interval_seconds();
            string current_interval_id = current_interval.to_string();
            bool have_interval_match = false;
            foreach (var opt in interval_options) if (opt.id == current_interval_id) have_interval_match = true;
            if (!have_interval_match) current_interval_id = "600"; // a custom/legacy value collapses to the closest preset shown

            var interval_row = new SelectionRow.with_options(
                _("Rotation Interval"), interval_options, current_interval_id);
            interval_row.visible = rotation_state.get_rotate_enabled();
            interval_row.selected.connect((id) => {
                int seconds;
                if (int.try_parse(id, out seconds)) rotation_state.set_rotate_interval_seconds(seconds);
            });
            grid_group.add_row(interval_row);

            rotate_row.switch_btn.notify["active"].connect(() => {
                bool enabled = rotate_row.switch_btn.active;
                rotation_state.set_rotate_enabled(enabled);
                interval_row.visible = enabled;
            });
```

- [ ] **Step 2: Build and verify**

```
meson compile -C build
meson test -C build -v
```

Expected: exit 0, all tests pass (this task adds no new meson test target; it's UI-only, verified by the build succeeding and matching the pattern of every other `SwitchRow`/`SelectionRow` pair already in this file, e.g. the `adaptive_row` block).

Manual verification: toggling "Rotate Wallpapers" off hides "Rotation Interval" and writes `0` to `~/.config/ncz-wallpaper/rotate-enabled`; changing the interval writes the matching seconds value to `~/.config/ncz-wallpaper/rotate-interval`; both files match what `ncz-wallpaper-daemon` already expects (confirm by reading the shipped script's `CONF_DIR` handling in `cix-installer/post-install/45-wallpaper-rotator.sh` — do not just trust this plan's own description of it, check the actual script before signing off).

- [ ] **Step 3: Commit**

```bash
git add src/components/sidebar/pages/desktop_page.vala
git commit -m "feat(wallpaper): add rotation on/off + interval controls"
```

---

## Post-plan note

This plan does not touch `cix-installer` at all — every file it changes lives in `singularity-shell`. The rotator daemon side (`45-wallpaper-rotator.sh`) is read-only context here: verify against it, never edit it as part of this plan. If the daemon's actual file names or defaults have drifted from what's documented in this plan's Global Constraints (they were last read 2026-09-04), that's a stop-and-flag moment, not a silent adaptation — the whole point of sharing state files with the daemon is that both sides agree on the format.
