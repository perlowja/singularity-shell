using GLib;
using Singularity;

private string root;

private void write_file(string path, string contents) {
    DirUtils.create_with_parents(Path.get_dirname(path), 0755);
    try {
        FileUtils.set_contents(path, contents);
    } catch (FileError e) {
        error("fixture write failed: %s", e.message);
    }
}

private string read_file(string path) {
    string contents = "";
    try {
        FileUtils.get_contents(path, out contents);
    } catch (FileError e) {
        return "";
    }
    return contents.strip();
}

private string chip(int n, string name, string driver, string device) {
    string device_dir = Path.build_filename(root, "sys", "devices", "platform", device);
    string driver_dir = Path.build_filename(root, "sys", "bus", "platform", "drivers", driver);
    DirUtils.create_with_parents(device_dir, 0755);
    DirUtils.create_with_parents(driver_dir, 0755);
    FileUtils.symlink(driver_dir, Path.build_filename(device_dir, "driver"));
    string hwmon = Path.build_filename(root, "sys", "class", "hwmon", "hwmon%d".printf(n));
    write_file(Path.build_filename(hwmon, "name"), name + "\n");
    FileUtils.symlink(device_dir, Path.build_filename(hwmon, "device"));
    return hwmon;
}

private void value(string dir, string name, string contents) {
    write_file(Path.build_filename(dir, name), contents + "\n");
}

private void cpu_temp(int millidegrees) {
    string dir = Path.build_filename(root, "sys", "class", "hwmon", "hwmon9");
    value(dir, "name", "coretemp");
    value(dir, "temp1_input", millidegrees.to_string());
    value(dir, "temp1_label", "Package id 0");
    value(dir, "temp1_crit", "100000");
}

private void remove_tree(File file) {
    try {
        if (file.query_file_type(FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == FileType.DIRECTORY) {
            var children = file.enumerate_children(FileAttribute.STANDARD_NAME,
                                                   FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = children.next_file()) != null) {
                remove_tree(file.get_child(info.get_name()));
            }
        }
        file.delete();
    } catch (Error e) {
    }
}

private FanController fresh_controller() {
    if (root != null) remove_tree(File.new_for_path(root));
    try {
        root = DirUtils.make_tmp("fan-control-XXXXXX");
    } catch (FileError e) {
        error("cannot create fixture root: %s", e.message);
    }
    cpu_temp(50000);
    return new FanController(root, Path.build_filename(root, "var"),
                             Path.build_filename(root, "run", "manual.conf"));
}

private string nct_with_points(int points) {
    string hw = chip(0, "nct6798", "nct6775", "nct6775.656");
    value(hw, "fan1_input", "900");
    value(hw, "pwm1", "80");
    value(hw, "pwm1_enable", "5");
    for (int i = 1; i <= points; i++) {
        value(hw, "pwm1_auto_point%d_temp".printf(i), (20000 + i * 10000).to_string());
        value(hw, "pwm1_auto_point%d_pwm".printf(i), (i * 40).to_string());
    }
    return hw;
}

private int[] default_temps() {
    return { 40000, 55000, 70000, 85000 };
}

private int[] default_percents() {
    return { 25, 40, 70, 100 };
}

private void test_curve_interpolates() {
    var curve = new FanCurve(default_temps(), default_percents());
    assert(curve.percent_at(30000) == 25);
    assert(curve.percent_at(47500) == 33);
    assert(curve.percent_at(70000) == 70);
    assert(curve.percent_at(99000) == 100);
}

private void test_next_percent_guards() {
    var curve = new FanCurve({ 40000, 55000, 70000, 85000 }, { 20, 20, 50, 60 });
    assert(FanController.next_percent(curve, 30000, 100000, 20) == FanController.MIN_PERCENT);
    assert(FanController.next_percent(curve, 96000, 100000, 20) == 100);
    assert(FanController.next_percent(curve, 30000, 100000, 80) == 75);
    assert(FanController.next_percent(curve, 70000, 100000, 20) == 50);
}

private void test_thinkpad_blocked_by_kernel() {
    var fc = fresh_controller();
    string hw = chip(0, "thinkpad", "thinkpad_hwmon", "thinkpad_hwmon");
    value(hw, "fan1_input", "0");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    write_file(Path.build_filename(root, "sys", "module", "thinkpad_acpi", "parameters", "fan_control"), "N\n");
    fc.scan();
    var ch = fc.find("thinkpad_hwmon-pwm1");
    assert(ch != null);
    assert(ch.method == "");
    assert("fan_control" in ch.reason);
}

private void test_thinkpad_allowed_is_software() {
    var fc = fresh_controller();
    string hw = chip(0, "thinkpad", "thinkpad_hwmon", "thinkpad_hwmon");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    write_file(Path.build_filename(root, "sys", "module", "thinkpad_acpi", "parameters", "fan_control"), "Y\n");
    fc.scan();
    assert(fc.find("thinkpad_hwmon-pwm1").method == "software");
}

private void test_unknown_driver_is_firmware_only() {
    var fc = fresh_controller();
    string hw = chip(0, "asusec", "asus_ec_sensors", "asus-ec-sensors");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    fc.scan();
    var ch = fc.find("asus-ec-sensors-pwm1");
    assert(ch.method == "");
    assert("asus_ec_sensors" in ch.reason);
    try {
        fc.apply(ch.id, default_temps(), default_percents());
        assert_not_reached();
    } catch (FanControlError e) {
        assert(e is FanControlError.UNSUPPORTED);
    }
}

private void test_validation_rejects_bad_curves() {
    var fc = fresh_controller();
    string hw = chip(0, "it8686", "it87", "it87.2624");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    fc.scan();
    var ch = fc.find("it87.2624-pwm1");
    int[,] bad = {
        { 40000, 55000, 70000, 0 },
        { 40000, 35000, 70000, 85000 },
        { 40000, 55000, 70000, 97000 },
        { 10000, 55000, 70000, 85000 }
    };
    for (int row = 0; row < 4; row++) {
        int[] temps = row == 0
            ? new int[] { 40000, 55000, 70000 }
            : new int[] { bad[row, 0], bad[row, 1], bad[row, 2], bad[row, 3] };
        int[] percents = row == 0 ? new int[] { 25, 40, 70 } : default_percents();
        try {
            fc.validate(ch, temps, percents, 100000);
            assert_not_reached();
        } catch (FanControlError e) {
            assert(e is FanControlError.INVALID_CURVE);
        }
    }
    try {
        fc.validate(ch, default_temps(), { 10, 40, 70, 100 }, 100000);
        assert_not_reached();
    } catch (FanControlError e) {
        assert(e is FanControlError.INVALID_CURVE);
    }
    try {
        fc.validate(ch, default_temps(), { 40, 30, 70, 100 }, 100000);
        assert_not_reached();
    } catch (FanControlError e) {
        assert(e is FanControlError.INVALID_CURVE);
    }
}

private void test_hardware_curve_written_and_reset() {
    var fc = fresh_controller();
    string hw = nct_with_points(5);
    fc.scan();
    var ch = fc.find("nct6775.656-pwm1");
    assert(ch.method == "hardware");
    assert(ch.max_points == 5);
    try {
        fc.apply(ch.id, default_temps(), default_percents());
    } catch (Error e) {
        error("apply failed: %s", e.message);
    }
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "5");
    assert(read_file(Path.build_filename(hw, "pwm1_auto_point2_temp")) == "55000");
    assert(read_file(Path.build_filename(hw, "pwm1_auto_point2_pwm")) == "102");
    assert(read_file(Path.build_filename(hw, "pwm1_auto_point5_temp")) == "86000");
    assert(read_file(Path.build_filename(hw, "pwm1_auto_point5_pwm")) == "255");
    assert(ch.active == "hardware");

    try {
        fc.reset(ch.id);
    } catch (Error e) {
        error("reset failed: %s", e.message);
    }
    assert(read_file(Path.build_filename(hw, "pwm1_auto_point2_temp")) == "40000");
    assert(read_file(Path.build_filename(hw, "pwm1_auto_point2_pwm")) == "80");
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "5");
    assert(ch.active == "firmware");
    assert(!("nct6775.656-pwm1" in read_file(Path.build_filename(root, "var", "curves.conf"))));
}

private void test_read_only_points_fall_back_to_software() {
    var fc = fresh_controller();
    string hw = nct_with_points(5);
    FileUtils.chmod(Path.build_filename(hw, "pwm1_auto_point3_pwm"), 0444);
    fc.scan();
    assert(fc.find("nct6775.656-pwm1").method == "software");
}

private void test_software_curve_and_crash_restore() {
    var fc = fresh_controller();
    string hw = chip(0, "it8686", "it87", "it87.2624");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    fc.scan();
    try {
        fc.apply("it87.2624-pwm1", default_temps(), default_percents());
    } catch (Error e) {
        error("apply failed: %s", e.message);
    }
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "1");
    assert(read_file(Path.build_filename(hw, "pwm1")) == "242");
    string state = Path.build_filename(root, "run", "manual.conf");
    assert("pwm1_enable" in read_file(state));

    assert(FanController.restore_from_state(state) == 1);
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "2");
    assert(!FileUtils.test(state, FileTest.EXISTS));
}

private void test_lost_temperature_hands_back_to_firmware() {
    var fc = fresh_controller();
    string hw = chip(0, "it8686", "it87", "it87.2624");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    fc.scan();
    try {
        fc.apply("it87.2624-pwm1", default_temps(), default_percents());
    } catch (Error e) {
        error("apply failed: %s", e.message);
    }
    FileUtils.unlink(Path.build_filename(root, "sys", "class", "hwmon", "hwmon9", "temp1_input"));
    fc.tick();
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "2");
    assert(fc.find("it87.2624-pwm1").active == "firmware");
}

private void test_external_takeover_drops_control() {
    var fc = fresh_controller();
    string hw = chip(0, "it8686", "it87", "it87.2624");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    fc.scan();
    try {
        fc.apply("it87.2624-pwm1", default_temps(), default_percents());
    } catch (Error e) {
        error("apply failed: %s", e.message);
    }
    value(hw, "pwm1_enable", "2");
    value(hw, "pwm1", "50");
    fc.tick();
    assert(read_file(Path.build_filename(hw, "pwm1")) == "50");
    assert(fc.find("it87.2624-pwm1").active == "firmware");
    assert(!FileUtils.test(Path.build_filename(root, "run", "manual.conf"), FileTest.EXISTS)
           || !("it87" in read_file(Path.build_filename(root, "run", "manual.conf"))));
}

private void test_release_all_restores_firmware() {
    var fc = fresh_controller();
    string hw = chip(0, "it8686", "it87", "it87.2624");
    value(hw, "pwm1", "128");
    value(hw, "pwm1_enable", "2");
    fc.scan();
    try {
        fc.apply("it87.2624-pwm1", default_temps(), default_percents());
    } catch (Error e) {
        error("apply failed: %s", e.message);
    }
    fc.release_all();
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "2");
    assert(!fc.has_software_curves());
    fc.reapply_saved();
    assert(read_file(Path.build_filename(hw, "pwm1_enable")) == "1");
}

public int main(string[] args) {
    Test.init(ref args);
    Log.set_always_fatal(LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
    Test.add_func("/fan-control/curve-interpolates", test_curve_interpolates);
    Test.add_func("/fan-control/next-percent-guards", test_next_percent_guards);
    Test.add_func("/fan-control/thinkpad-blocked", test_thinkpad_blocked_by_kernel);
    Test.add_func("/fan-control/thinkpad-allowed", test_thinkpad_allowed_is_software);
    Test.add_func("/fan-control/unknown-driver", test_unknown_driver_is_firmware_only);
    Test.add_func("/fan-control/validation", test_validation_rejects_bad_curves);
    Test.add_func("/fan-control/hardware-curve", test_hardware_curve_written_and_reset);
    Test.add_func("/fan-control/read-only-points", test_read_only_points_fall_back_to_software);
    Test.add_func("/fan-control/software-crash-restore", test_software_curve_and_crash_restore);
    Test.add_func("/fan-control/lost-temperature", test_lost_temperature_hands_back_to_firmware);
    Test.add_func("/fan-control/external-takeover", test_external_takeover_drops_control);
    Test.add_func("/fan-control/release-all", test_release_all_restores_firmware);
    int rc = Test.run();
    if (root != null) remove_tree(File.new_for_path(root));
    return rc;
}
