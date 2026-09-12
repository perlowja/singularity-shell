using GLib;
using Gee;
using Singularity;

private string fixture_root;

private string make_dir(string name) {
    string path = Path.build_filename(fixture_root, name);
    DirUtils.create_with_parents(path, 0700);
    return path;
}

private string image_file(string dir, string name) {
    string path = Path.build_filename(dir, name + ".svg");
    try {
        DirUtils.create_with_parents(dir, 0700);
        FileUtils.set_contents(path,
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"><rect width=\"1\" height=\"1\"/></svg>");
    } catch (Error e) { error("fixture: %s", e.message); }
    return File.new_for_path(path).get_uri();
}

private void write_collection(string registry, string id, string dir) {
    try {
        DirUtils.create_with_parents(registry, 0700);
        FileUtils.set_contents(Path.build_filename(registry, id + ".collection"),
            "[Collection]\nId=%s\nName=%s\nDir=%s\n".printf(id, id, dir));
    } catch (Error e) { error("fixture: %s", e.message); }
}

// ---- pick(): which image is next ------------------------------------------

private void test_pick_single_candidate() {
    var uris = new ArrayList<string>();
    uris.add("file:///a.png");
    // The only image in the pack is also the one on screen: keep showing it
    // rather than report "nothing to rotate to".
    assert(WallpaperRotator.pick(uris, "file:///a.png", 0) == "file:///a.png");
}

private void test_pick_is_deterministic_for_a_given_roll() {
    var uris = new ArrayList<string>();
    uris.add("file:///a.png");
    uris.add("file:///b.png");
    uris.add("file:///c.png");
    assert(WallpaperRotator.pick(uris, null, 0) == "file:///a.png");
    assert(WallpaperRotator.pick(uris, null, 1) == "file:///b.png");
    assert(WallpaperRotator.pick(uris, null, 5) == "file:///c.png");
}

private void test_pick_never_returns_the_current_wallpaper() {
    var uris = new ArrayList<string>();
    uris.add("file:///a.png");
    uris.add("file:///b.png");
    uris.add("file:///c.png");
    // A rotation that lands on the image already showing reads as a broken
    // feature, so every roll must skip it.
    for (uint32 roll = 0; roll < 12; roll++) {
        assert(WallpaperRotator.pick(uris, "file:///b.png", roll) != "file:///b.png");
    }
}

private void test_pick_on_empty_list() {
    assert(WallpaperRotator.pick(new ArrayList<string>(), null, 0) == null);
}

// ---- choose_next(): which collection ---------------------------------------

private void test_rotates_within_the_selected_collection_only() {
    string registry = make_dir("registry-scoped");
    string alpha = make_dir("alpha");
    string beta = make_dir("beta");
    string a1 = image_file(alpha, "a1");
    string a2 = image_file(alpha, "a2");
    image_file(beta, "b1");
    write_collection(registry, "alpha", alpha);
    write_collection(registry, "beta", beta);

    string config = make_dir("config-scoped");
    new WallpaperRotationState(config).set_selected_collection("alpha");

    var rotator = new WallpaperRotator(config, { registry });
    for (int i = 0; i < 8; i++) {
        string? chosen = rotator.choose_next();
        assert(chosen == a1 || chosen == a2);
    }
}

private void test_stale_collection_id_falls_back_to_the_first() {
    string registry = make_dir("registry-stale");
    string alpha = make_dir("alpha-stale");
    string only = image_file(alpha, "only");
    write_collection(registry, "alpha", alpha);

    string config = make_dir("config-stale");
    // A pack the user had selected and has since uninstalled must not leave
    // the rotator doing nothing forever.
    new WallpaperRotationState(config).set_selected_collection("uninstalled-pack");

    var rotator = new WallpaperRotator(config, { registry });
    assert(rotator.choose_next() == only);
}

private void test_empty_collection_leaves_the_wallpaper_alone() {
    string registry = make_dir("registry-empty");
    string empty = make_dir("empty-pack");
    write_collection(registry, "empty", empty);

    string config = make_dir("config-empty");
    new WallpaperRotationState(config).set_selected_collection("empty");

    var rotator = new WallpaperRotator(config, { registry });
    assert(rotator.choose_next() == null);
}

private void test_no_registry_at_all() {
    var rotator = new WallpaperRotator(make_dir("config-none"),
                                       { Path.build_filename(fixture_root, "no-such-registry") });
    assert(rotator.choose_next() == null);
}

// ---- rotate_now(): the announcement ----------------------------------------

private void test_rotate_now_announces_and_records_the_choice() {
    string registry = make_dir("registry-emit");
    string pack = make_dir("emit-pack");
    string only = image_file(pack, "only");
    write_collection(registry, "emit", pack);

    string config = make_dir("config-emit");
    new WallpaperRotationState(config).set_selected_collection("emit");

    var rotator = new WallpaperRotator(config, { registry });
    string? announced = null;
    rotator.wallpaper_selected.connect((uri) => { announced = uri; });
    rotator.rotate_now();

    assert(announced == only);
    // Recorded, so the next rotation knows what is already on screen.
    assert(rotator.current_uri == only);
}

private void test_rotate_now_announces_nothing_when_there_is_nothing() {
    string config = make_dir("config-silent");
    var rotator = new WallpaperRotator(config,
                                       { Path.build_filename(fixture_root, "no-such-registry") });
    bool announced = false;
    rotator.wallpaper_selected.connect((uri) => { announced = true; });
    rotator.rotate_now();
    assert(!announced);
}

private void test_choose_next_for_excludes_the_supplied_wallpaper() {
    string registry = make_dir("registry-exclude");
    string pack = make_dir("exclude-pack");
    string a = image_file(pack, "a");
    string b = image_file(pack, "b");
    write_collection(registry, "exclude", pack);

    string config = make_dir("config-exclude");
    new WallpaperRotationState(config).set_selected_collection("exclude");

    // The threaded rotation passes a main-thread snapshot rather than
    // reading the property, so the exclusion has to hold for the argument.
    var rotator = new WallpaperRotator(config, { registry });
    for (int i = 0; i < 8; i++) {
        assert(rotator.choose_next_for(a) == b);
        assert(rotator.choose_next_for(b) == a);
    }
}

// The path every real rotation takes: the scan happens on a worker thread and
// the result is announced back on the main loop. rotate_now() is the same
// decision made synchronously, so testing only that would leave the threaded
// hand-off -- the part that actually runs -- unexercised.
private void test_rotate_async_announces_on_the_main_loop() {
    string registry = make_dir("registry-async");
    string pack = make_dir("async-pack");
    string only = image_file(pack, "only");
    write_collection(registry, "async", pack);

    string config = make_dir("config-async");
    new WallpaperRotationState(config).set_selected_collection("async");

    var rotator = new WallpaperRotator(config, { registry });
    var loop = new MainLoop();
    string? announced = null;
    rotator.wallpaper_selected.connect((uri) => {
        announced = uri;
        loop.quit();
    });
    // Fail on the assertion below rather than hang the suite if the hand-off
    // never happens. The flag matters: once this fires the source is already
    // gone, and removing it again is a GLib critical that would mask the real
    // failure with "Source ID was not found".
    bool timed_out = false;
    uint bail = Timeout.add_seconds(10, () => {
        timed_out = true;
        loop.quit();
        return Source.REMOVE;
    });

    rotator.rotate_async();
    loop.run();
    if (!timed_out) Source.remove(bail);

    assert(!timed_out);
    assert(announced == only);
    assert(rotator.current_uri == only);
}

// ---- reschedule(): the switch and the interval actually govern the timer ----

// Rotation must not start on its own. Before a runtime consumer existed the
// "absent means enabled" default was inert; now it would mean every install
// that never touched the switch starts replacing a hand-picked wallpaper.
private void test_untouched_install_does_not_rotate() {
    string config = make_dir("config-untouched");
    var rotator = new WallpaperRotator(config, { make_dir("registry-untouched") });
    rotator.start();
    assert(rotator.armed_interval_seconds == 0);
    rotator.stop();
}

private void test_timer_follows_the_rotation_state() {
    string config = make_dir("config-timer");
    var state = new WallpaperRotationState(config);
    var rotator = new WallpaperRotator(config, { make_dir("registry-timer") });

    // Nothing written yet: off, so no timer at all.
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 0);

    // Turning it on is what starts it, at the default period.
    state.set_rotate_enabled(true);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 600);

    state.set_rotate_interval_seconds(3600);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 3600);

    // The switch is what decides whether a timer exists at all.
    state.set_rotate_enabled(false);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 0);

    state.set_rotate_enabled(true);
    rotator.reschedule();
    assert(rotator.armed_interval_seconds == 3600);

    rotator.stop();
    assert(rotator.armed_interval_seconds == 0);
}

public int main(string[] args) {
    Test.init(ref args);
    try { fixture_root = DirUtils.make_tmp("wallpaper-rotator-XXXXXX"); }
    catch (Error e) { error("fixture: %s", e.message); }

    Test.add_func("/wallpaper-rotator/pick-single-candidate", test_pick_single_candidate);
    Test.add_func("/wallpaper-rotator/pick-deterministic-roll", test_pick_is_deterministic_for_a_given_roll);
    Test.add_func("/wallpaper-rotator/pick-skips-current", test_pick_never_returns_the_current_wallpaper);
    Test.add_func("/wallpaper-rotator/pick-empty", test_pick_on_empty_list);
    Test.add_func("/wallpaper-rotator/scoped-to-selected-collection", test_rotates_within_the_selected_collection_only);
    Test.add_func("/wallpaper-rotator/stale-id-falls-back", test_stale_collection_id_falls_back_to_the_first);
    Test.add_func("/wallpaper-rotator/empty-collection-is-a-no-op", test_empty_collection_leaves_the_wallpaper_alone);
    Test.add_func("/wallpaper-rotator/no-registry", test_no_registry_at_all);
    Test.add_func("/wallpaper-rotator/rotate-now-announces", test_rotate_now_announces_and_records_the_choice);
    Test.add_func("/wallpaper-rotator/rotate-now-silent-when-empty", test_rotate_now_announces_nothing_when_there_is_nothing);
    Test.add_func("/wallpaper-rotator/choose-next-for-excludes", test_choose_next_for_excludes_the_supplied_wallpaper);
    Test.add_func("/wallpaper-rotator/rotate-async-announces", test_rotate_async_announces_on_the_main_loop);
    Test.add_func("/wallpaper-rotator/untouched-install-does-not-rotate", test_untouched_install_does_not_rotate);
    Test.add_func("/wallpaper-rotator/timer-follows-state", test_timer_follows_the_rotation_state);
    return Test.run();
}
