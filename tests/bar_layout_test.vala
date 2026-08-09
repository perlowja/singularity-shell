using GLib;
using Singularity;

private BarLayout create_layout(string[] left, string[] center, string[] right) {
    return new BarLayout(
        { "overview", "applications", "system", "clock" },
        { "overview" },
        { "applications" },
        { "system", "clock" },
        left,
        center,
        right
    );
}

private void test_normalizes_saved_layout() {
    var layout = create_layout(
        { "overview", "unknown", "overview" },
        {},
        { "clock" }
    );

    assert(layout.get_items(BarSection.LEFT).length == 1);
    assert(layout.get_items(BarSection.LEFT)[0] == "overview");
    assert(layout.get_items(BarSection.CENTER)[0] == "applications");
    assert(layout.get_items(BarSection.RIGHT)[0] == "clock");
    assert(layout.get_items(BarSection.RIGHT)[1] == "system");
}

private void test_default_layout_centers_applications() {
    var layout = create_layout({}, {}, {});

    assert(layout.get_section("applications") == BarSection.CENTER);
    assert(layout.get_items(BarSection.CENTER)[0] == "applications");
}

private void test_moves_between_sections() {
    var layout = create_layout({ "overview" }, { "applications" }, { "system", "clock" });

    assert(layout.move("clock", BarSection.LEFT, 1));
    assert(layout.get_items(BarSection.LEFT)[1] == "clock");
    assert(layout.get_section("clock") == BarSection.LEFT);
    assert(!layout.move("missing", BarSection.CENTER, 0));
}

private void test_reorders_items() {
    var layout = create_layout({ "overview" }, { "applications" }, { "system", "clock" });

    assert(layout.move_down("system"));
    assert(layout.get_items(BarSection.RIGHT)[0] == "clock");
    assert(layout.move_up("system"));
    assert(layout.get_items(BarSection.RIGHT)[0] == "system");
    assert(!layout.move_up("system"));
}

private void test_moves_temporary_item_id() {
    var layout = create_layout({ "overview" }, { "applications" }, { "system", "clock" });
    string payload = "panel:clock";
    string item_id = payload.substring("panel:".length);

    assert(layout.move(item_id, BarSection.LEFT, 1));
    payload = "";
    item_id = "";

    string[] saved_items = layout.get_items(BarSection.LEFT);
    foreach (string item in saved_items) {
        assert(item.validate());
    }
    var saved_value = new Variant.strv(saved_items);
    assert(saved_value.n_children() == saved_items.length);
    assert(saved_items[1] == "clock");
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/bar-layout/normalizes-saved-layout", test_normalizes_saved_layout);
    Test.add_func("/bar-layout/default-centers-applications", test_default_layout_centers_applications);
    Test.add_func("/bar-layout/moves-between-sections", test_moves_between_sections);
    Test.add_func("/bar-layout/reorders-items", test_reorders_items);
    Test.add_func("/bar-layout/moves-temporary-item-id", test_moves_temporary_item_id);
    return Test.run();
}
