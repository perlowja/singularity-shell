using GLib;
using Singularity;

private const string PROVIDERS = "{\"schema\":1,\"providers\":{\"pling\":{\"base\":\"https://api.pling.com/ocs/v1/\"},\"kde-look\":{\"base\":\"https://api.kde-look.org/ocs/v1/\"}}}";
private const string INDEX = "{\"schema\":1,\"entries\":[{\"ref\":\"pling:300\",\"name\":\"Wallpapers\",\"display_name\":\"Desktop\",\"usable\":true},{\"ref\":\"pling:1\",\"name\":\"Phone\",\"usable\":false},{\"ref\":\"kde-look:2\",\"name\":\"Other\",\"usable\":true},{\"ref\":\"pling:300\",\"name\":\"Duplicate\",\"usable\":true}]}";
private string browse(string items, string provider = "pling", string category = "300") {
    return "{\"schema\":1,\"provider\":\"%s\",\"category\":\"%s\",\"items\":%s}".printf(provider, category, items);
}
private const string ITEM = "{\"provider\":\"pling\",\"id\":\"123\",\"name\":\"Space & <Stars>\",\"author\":null,\"preview\":null}";
private const string ITEM_TAGGED = "{\"provider\":\"pling\",\"id\":\"456\",\"name\":\"Tagged\",\"tags\":[\"nature\",\" abstract \",\"nature\",\"\"]}";
private const string ITEM_NO_TAGS = "{\"provider\":\"pling\",\"id\":\"789\",\"name\":\"Plain\"}";
private const string ITEM_EMPTY_TAGS = "{\"provider\":\"pling\",\"id\":\"321\",\"name\":\"Empty\",\"tags\":[]}";
private void test_providers() {
    try { var rows = WallpaperOcs.providers(PROVIDERS); assert(rows.size == 2); assert(rows[0].id == "kde-look"); assert(rows[1].id == "pling"); } catch (Error e) { error("%s", e.message); }
}
private void test_categories() {
    try { var rows = WallpaperOcs.categories(INDEX, "pling"); assert(rows.size == 1); assert(rows[0].id == "300"); assert(rows[0].name == "Desktop"); } catch (Error e) { error("%s", e.message); }
}
private void test_items() {
    try { var rows = WallpaperOcs.items(browse("[" + ITEM + "," + ITEM + "]"), "pling", "300"); assert(rows.size == 1); assert(rows[0].key == "pling:123"); assert(rows[0].author == ""); assert(rows[0].license == ""); assert(rows[0].preview == ""); assert(rows[0].name == "Space & <Stars>"); assert(rows[0].tags.length == 0); } catch (Error e) { error("%s", e.message); }
}
private void test_tags() {
    // Present, deduplicated, whitespace-stripped, blanks dropped, order preserved.
    try {
        var rows = WallpaperOcs.items(browse("[" + ITEM_TAGGED + "]"), "pling", "300");
        assert(rows.size == 1);
        assert(rows[0].tags.length == 2);
        assert(rows[0].tags[0] == "nature");
        assert(rows[0].tags[1] == "abstract");
    } catch (Error e) { error("tagged: %s", e.message); }
    // Explicit empty array collapses to empty.
    try {
        var rows = WallpaperOcs.items(browse("[" + ITEM_EMPTY_TAGS + "]"), "pling", "300");
        assert(rows.size == 1);
        assert(rows[0].tags.length == 0);
    } catch (Error e) { error("empty-tags: %s", e.message); }
    // Absent field collapses to empty (matches author/license/preview leniency).
    try {
        var rows = WallpaperOcs.items(browse("[" + ITEM_NO_TAGS + "]"), "pling", "300");
        assert(rows.size == 1);
        assert(rows[0].tags.length == 0);
    } catch (Error e) { error("no-tags: %s", e.message); }
}
private void test_empty() {
    try { assert(WallpaperOcs.items(browse("[]"), "pling", "300").size == 0); } catch (Error e) { error("%s", e.message); }
}
private void test_invalid() {
    string[] bad = { "null", "[]", "{}", "not json", "{\"schema\":2,\"providers\":{}}", "{\"schema\":\"1\",\"providers\":{}}", "{\"schema\":1,\"providers\":[]}", "{\"schema\":1,\"providers\":{\"--bad\":{}}}" };
    foreach (string data in bad) { bool rejected = false; try { WallpaperOcs.providers(data); } catch (Error e) { rejected = true; } assert(rejected); }
}
private void test_bad_items() {
    string[] bad = { browse("[]", "kde-look"), browse("[]", "pling", "2"), browse("null"), browse("[null]"), browse("[{\"provider\":\"pling\",\"id\":123,\"name\":\"x\"}]"), browse("[" + ITEM.replace("pling", "kde-look") + "]"), browse("[" + ITEM.replace("null", "42") + "]"), browse("[" + ITEM.replace("null", "{\"tags\":42}") + "]"), browse("[" + ITEM.replace("null", "{\"tags\":[\"ok\",42]}") + "]") };
    foreach (string data in bad) { bool rejected = false; try { WallpaperOcs.items(data, "pling", "300"); } catch (Error e) { rejected = true; } assert(rejected); }
}
private void test_bad_categories() {
    foreach (string data in new string[] { INDEX.replace("true", "\"true\""), INDEX.replace("pling:300", "pling:--bad") }) {
        bool rejected = false; try { WallpaperOcs.categories(data, "pling"); } catch (Error e) { rejected = true; } assert(rejected);
    }
}
private void test_import_retry() {
    var state = new WallpaperOcsImports(); assert(state.begin("pling:123")); assert(state.busy); assert(!state.begin("pling:123")); assert(!state.begin("pling:456")); state.fail("pling:456"); assert(state.busy); state.fail("pling:123"); assert(!state.busy); assert(!state.is_added("pling:123")); assert(state.begin("pling:123"));
}
private void remove_tree(string path) {
    try { var dir = Dir.open(path); string? name; while ((name = dir.read_name()) != null) { string child = Path.build_filename(path, name); if (FileUtils.test(child, FileTest.IS_DIR)) remove_tree(child); else FileUtils.unlink(child); } DirUtils.remove(path); } catch (Error e) { error("cleanup: %s", e.message); }
}

// Build the per-image sidecar JSON shape that the ncz-wallpaper-ocs helper
// now writes: schema=1, origin="ocs", pack_id="imported-ocs", with provider
// + source.ocs_id encoded in the same fields discover()/complete() parse.
private string make_sidecar(string provider, string ocs_id, string image_filename) {
    return "{\"schema\":1,\"origin\":\"ocs\",\"pack_id\":\"imported-ocs\",\"image\":{\"file\":\"" + image_filename + "\"}," +
           "\"provider\":\"" + provider + "\"," +
           "\"source\":{\"ocs_id\":\"" + ocs_id + "\",\"detailpage\":\"https://example/" + ocs_id + "\"," +
           "\"download_url\":\"https://example/file\",\"downloadname1\":\"" + image_filename + "\",\"downloadsize1_kib\":42,\"tags\":[]}}";
}

// Build the new import-command return payload: pack_id fixed at "imported-ocs",
// destination = shared directory, collection = shared .collection file, images
// each with {file, sidecar}. No "pack_json" field any more (deleted).
private string make_payload(string destination, string collection_path, string image_filename, string sidecar_path) {
    return "{\"pack_id\":\"imported-ocs\",\"destination\":\"" + destination +
           "\",\"collection\":\"" + collection_path +
           "\",\"images\":[{\"file\":\"" + image_filename + "\",\"title\":\"Test\",\"sidecar\":\"" + sidecar_path + "\"}]}";
}

private void test_import_complete() {
    // New model: one shared "imported-ocs" directory + .collection file, with
    // a per-image sidecar next to each normalized image. The pack_id returned
    // by the helper is the fixed string "imported-ocs", not a per-import id.
    string root = "";
    try {
        root = DirUtils.make_tmp("ocs-test-XXXXXX");
        string pack_dir = Path.build_filename(root, "imported-ocs");
        DirUtils.create(pack_dir, 0700);
        string collection_path = Path.build_filename(root, "imported-ocs.collection");
        FileUtils.set_contents(collection_path,
            "[Collection]\nId=imported-ocs\nName=Imported from OCS\nType=static\nDir=" + pack_dir + "\n");
        string image_filename = "pling-123-01-foo.jpg";
        string sidecar_filename = "pling-123-01-foo.json";
        FileUtils.set_contents(Path.build_filename(pack_dir, image_filename), "fixture-jpg");
        FileUtils.set_contents(Path.build_filename(pack_dir, sidecar_filename),
            make_sidecar("pling", "123", image_filename));

        string result = make_payload(pack_dir, collection_path, image_filename,
                                     sidecar_filename);

        var state = new WallpaperOcsImports();
        assert(state.begin("pling:123"));
        // Missing .jpg -> complete() must reject and NOT mark added.
        bool rejected = false;
        try { state.complete("pling:123", result.replace("pling-123-01-foo.jpg", "missing.jpg"), {root}); }
        catch (Error e) { rejected = true; }
        assert(rejected);
        assert(!state.is_added("pling:123"));
        assert(state.busy);
        // Happy path.
        state.complete("pling:123", result, {root});
        assert(!state.busy);
        assert(state.is_added("pling:123"));
        assert(!state.begin("pling:123"));

        // A fresh imports model loaded from disk sees the import via discover().
        var reopened = new WallpaperOcsImports();
        reopened.discover(WallpaperCollections.parse({root}));
        assert(reopened.is_added("pling:123"));
        assert(!reopened.is_added("kde-look:123"));

        // If the sidecar disappears, the key is no longer found. discover()
        // must not crash, just not include it.
        FileUtils.unlink(Path.build_filename(pack_dir, sidecar_filename));
        var missing = new WallpaperOcsImports();
        missing.discover(WallpaperCollections.parse({root}));
        assert(!missing.is_added("pling:123"));
    } catch (Error e) { error("%s", e.message); }
    remove_tree(root);
}

private void test_discover_collects_multiple_sidecars_in_one_dir() {
    // The shared imported-ocs directory can hold many images from many
    // providers; discover() must add a key for each sidecar, not just the
    // first. This is the key behaviour that makes the old one-pack-per-import
    // scan obsolete: discover() now means "scan sidecars, not a single
    // pack.json".
    string root = "";
    try {
        root = DirUtils.make_tmp("ocs-test-XXXXXX");
        string pack_dir = Path.build_filename(root, "imported-ocs");
        DirUtils.create(pack_dir, 0700);
        FileUtils.set_contents(Path.build_filename(root, "imported-ocs.collection"),
            "[Collection]\nId=imported-ocs\nName=Imported from OCS\nType=static\nDir=" + pack_dir + "\n");
        // Two images from different providers, each with its sidecar.
        FileUtils.set_contents(Path.build_filename(pack_dir, "pling-111-01-a.jpg"), "x");
        FileUtils.set_contents(Path.build_filename(pack_dir, "pling-111-01-a.json"),
            make_sidecar("pling", "111", "pling-111-01-a.jpg"));
        FileUtils.set_contents(Path.build_filename(pack_dir, "kde-look-222-01-b.jpg"), "x");
        FileUtils.set_contents(Path.build_filename(pack_dir, "kde-look-222-01-b.json"),
            make_sidecar("kde-look", "222", "kde-look-222-01-b.jpg"));

        var state = new WallpaperOcsImports();
        state.discover(WallpaperCollections.parse({root}));
        assert(state.is_added("pling:111"));
        assert(state.is_added("kde-look:222"));
        assert(!state.is_added("pling:999"));
    } catch (Error e) { error("%s", e.message); }
    remove_tree(root);
}

private void test_discover_skips_orphan_sidecar_without_image() {
    // A sidecar JSON without its paired .jpg must NOT count as an import.
    // discover() must not crash, just skip it -- this is the safety property
    // that kept the old code honest (only normalized image files count, not
    // metadata alone) applied to the new per-image model.
    string root = "";
    try {
        root = DirUtils.make_tmp("ocs-test-XXXXXX");
        string pack_dir = Path.build_filename(root, "imported-ocs");
        DirUtils.create(pack_dir, 0700);
        FileUtils.set_contents(Path.build_filename(root, "imported-ocs.collection"),
            "[Collection]\nId=imported-ocs\nDir=" + pack_dir + "\n");
        FileUtils.set_contents(Path.build_filename(pack_dir, "pling-333-01-c.json"),
            make_sidecar("pling", "333", "pling-333-01-c.jpg"));

        var state = new WallpaperOcsImports();
        state.discover(WallpaperCollections.parse({root}));
        assert(!state.is_added("pling:333"));
    } catch (Error e) { error("%s", e.message); }
    remove_tree(root);
}

private void test_discover_tolerates_old_shape_directory() {
    // Old-shape directory left over from one-pack-per-import testing has a
    // pack.json but no sidecars. discover() must skip it silently rather
    // than error. This is the explicit "do not crash on the old convention"
    // requirement.
    string root = "";
    try {
        root = DirUtils.make_tmp("ocs-test-XXXXXX");
        string old_pack = Path.build_filename(root, "ocs-pling-555-oldstyle");
        DirUtils.create(old_pack, 0700);
        FileUtils.set_contents(Path.build_filename(root, "ocs-pling-555-oldstyle.collection"),
            "[Collection]\nId=ocs-pling-555-oldstyle\nName=Old\nDir=" + old_pack + "\n");
        FileUtils.set_contents(Path.build_filename(old_pack, "pack.json"),
            "{\"origin\":\"ocs\",\"provider\":\"pling\",\"source\":{\"ocs_id\":\"555\"}}");
        FileUtils.set_contents(Path.build_filename(old_pack, "01.jpg"), "oldshape");

        var state = new WallpaperOcsImports();
        state.discover(WallpaperCollections.parse({root}));
        assert(!state.is_added("pling:555"));
    } catch (Error e) { error("%s", e.message); }
    remove_tree(root);
}

private void test_import_complete_rejects_payload_without_sidecar_path() {
    // Backwards-safety: a payload that still has the old per-image shape
    // (no "sidecar" field per image) must be rejected. The Python helper
    // generates sidecars now, so a missing one is a real failure, not a
    // legacy shape we silently accept.
    string root = "";
    try {
        root = DirUtils.make_tmp("ocs-test-XXXXXX");
        string pack_dir = Path.build_filename(root, "imported-ocs");
        DirUtils.create(pack_dir, 0700);
        string collection_path = Path.build_filename(root, "imported-ocs.collection");
        FileUtils.set_contents(collection_path,
            "[Collection]\nId=imported-ocs\nDir=" + pack_dir + "\n");
        string image_filename = "pling-777-01-x.jpg";
        FileUtils.set_contents(Path.build_filename(pack_dir, image_filename), "fixture");
        // Build a payload that looks almost right except the per-image entry
        // lacks the "sidecar" field.
        string bad_payload = "{\"pack_id\":\"imported-ocs\",\"destination\":\"" + pack_dir +
                             "\",\"collection\":\"" + collection_path +
                             "\",\"images\":[{\"file\":\"" + image_filename + "\",\"title\":\"x\"}]}";
        var state = new WallpaperOcsImports();
        assert(state.begin("pling:777"));
        bool rejected = false;
        try { state.complete("pling:777", bad_payload, {root}); }
        catch (Error e) { rejected = true; }
        assert(rejected);
        assert(!state.is_added("pling:777"));
    } catch (Error e) { error("%s", e.message); }
    remove_tree(root);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/ocs/providers", test_providers); Test.add_func("/ocs/categories", test_categories); Test.add_func("/ocs/items", test_items); Test.add_func("/ocs/tags", test_tags); Test.add_func("/ocs/empty", test_empty); Test.add_func("/ocs/invalid", test_invalid); Test.add_func("/ocs/bad-items", test_bad_items); Test.add_func("/ocs/bad-categories", test_bad_categories); Test.add_func("/ocs/import-retry", test_import_retry); Test.add_func("/ocs/import-complete", test_import_complete); Test.add_func("/ocs/discover-collects-multiple-sidecars-in-one-dir", test_discover_collects_multiple_sidecars_in_one_dir); Test.add_func("/ocs/discover-skips-orphan-sidecar-without-image", test_discover_skips_orphan_sidecar_without_image); Test.add_func("/ocs/discover-tolerates-old-shape-directory", test_discover_tolerates_old_shape_directory); Test.add_func("/ocs/import-complete-rejects-payload-without-sidecar-path", test_import_complete_rejects_payload_without_sidecar_path);
    return Test.run();
}
