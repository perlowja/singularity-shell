using GLib;

namespace Singularity {

    [DBus (name = "dev.sinty.FanControl1.Error")]
    public errordomain FanControlError {
        UNKNOWN_CHANNEL,
        UNSUPPORTED,
        INVALID_CURVE,
        WRITE_FAILED,
        NOT_AUTHORIZED
    }

    public class FanCurve : Object {
        public int[] temps;
        public int[] percents;

        public FanCurve(int[] temps, int[] percents) {
            this.temps = temps;
            this.percents = percents;
        }

        public int percent_at(int millidegrees) {
            int n = temps.length;
            if (millidegrees <= temps[0]) return percents[0];
            for (int i = 1; i < n; i++) {
                if (millidegrees <= temps[i]) {
                    double t = (double) (millidegrees - temps[i - 1]) / (double) (temps[i] - temps[i - 1]);
                    return (int) Math.round(percents[i - 1] + t * (percents[i] - percents[i - 1]));
                }
            }
            return percents[n - 1];
        }
    }

    public class FanChannel : Object {
        public string id = "";
        public string hwmon_path = "";
        public int pwm = 0;
        public string chip = "";
        public string driver = "";
        public string label = "";
        public string method = "";
        public string reason = "";
        public int max_points = FanController.MAX_POINTS;
        public int chip_points = 0;
        public bool probed = false;
        public FanCurve? curve = null;
        public string active = "firmware";
        public int firmware_enable = 2;
        public int last_percent = 100;

        public string enable_path {
            owned get { return "%s/pwm%d_enable".printf(hwmon_path, pwm); }
        }

        public string pwm_path {
            owned get { return "%s/pwm%d".printf(hwmon_path, pwm); }
        }

        public string point_path(int point, string kind) {
            return "%s/pwm%d_auto_point%d_%s".printf(hwmon_path, pwm, point, kind);
        }
    }

    public class FanController : Object {
        public const int MIN_PERCENT = 20;
        public const int MIN_POINTS = 4;
        public const int MAX_POINTS = 6;
        public const int MIN_CURVE_MILLIDEGREES = 20000;
        public const int CRIT_MARGIN_MILLIDEGREES = 5000;
        public const int RAMP_DOWN_PERCENT = 5;
        public const int HARDWARE_CURVE_ENABLE = 5;
        public const int TICK_SECONDS = 2;
        public const int RESUME_SETTLE_SECONDS = 10;

        private const string[] SOFTWARE_DRIVERS = {
            "nct6775", "it87", "f71882fg", "thinkpad_hwmon", "dell_smm_hwmon", "amdgpu"
        };
        private const string[] HARDWARE_DRIVERS = { "nct6775" };

        public string sysfs_root { get; construct; }
        public string config_dir { get; construct; }
        public string state_path { get; construct; }

        private SensorMonitor sensors;
        private Gee.ArrayList<FanChannel> channels = new Gee.ArrayList<FanChannel>();
        private uint tick_id = 0;
        private int64 last_activity_us = 0;

        public signal void changed();

        public FanController(string sysfs_root, string config_dir, string state_path) {
            Object(sysfs_root: sysfs_root, config_dir: config_dir, state_path: state_path);
        }

        construct {
            sensors = new SensorMonitor();
            sensors.sysfs_root = sysfs_root;
            sensors.gpu_sampling = false;
            last_activity_us = get_monotonic_time();
        }

        public void start() {
            scan();
            reapply_saved();
            if (tick_id == 0) {
                tick_id = Timeout.add_seconds(TICK_SECONDS, () => {
                    tick();
                    return Source.CONTINUE;
                });
            }
        }

        public void touch() {
            last_activity_us = get_monotonic_time();
        }

        public int idle_seconds() {
            return (int) ((get_monotonic_time() - last_activity_us) / 1000000);
        }

        public bool has_software_curves() {
            foreach (var ch in channels) {
                if (ch.active == "software") return true;
            }
            return false;
        }

        public Gee.List<FanChannel> list() {
            return channels.read_only_view;
        }

        public FanChannel? find(string id) {
            foreach (var ch in channels) {
                if (ch.id == id) return ch;
            }
            return null;
        }

        private static string? read_line(string path) {
            string contents;
            try {
                if (!FileUtils.get_contents(path, out contents)) return null;
            } catch (FileError e) {
                return null;
            }
            return contents.strip();
        }

        private static int read_int(string path, int fallback) {
            string? raw = read_line(path);
            int64 value = 0;
            if (raw == null || !int64.try_parse(raw, out value)) return fallback;
            return (int) value;
        }

        public static bool write_value(string path, int value) {
            int fd = Posix.open(path, Posix.O_WRONLY | Posix.O_TRUNC);
            if (fd < 0) return false;
            string text = "%d\n".printf(value);
            ssize_t written = Posix.write(fd, text, text.length);
            bool closed = Posix.close(fd) == 0;
            return written == text.length && closed;
        }

        private static bool is_writable(string path) {
            Posix.Stat st;
            if (Posix.stat(path, out st) != 0) return false;
            return (st.st_mode & Posix.S_IWUSR) != 0;
        }

        private static string link_basename(string path) {
            try {
                return Path.get_basename(FileUtils.read_link(path));
            } catch (FileError e) {
                return "";
            }
        }

        public void scan() {
            var found = new Gee.ArrayList<FanChannel>();
            string hwmon_dir = sysfs_root + "/sys/class/hwmon";
            Dir dir;
            try {
                dir = Dir.open(hwmon_dir, 0);
            } catch (FileError e) {
                channels = found;
                return;
            }
            string? node;
            while ((node = dir.read_name()) != null) {
                string base_path = hwmon_dir + "/" + node;
                string chip = read_line(base_path + "/name") ?? node;
                string driver = link_basename(base_path + "/device/driver");
                string device = link_basename(base_path + "/device");
                if (device == "") device = chip;
                for (int pwm = 1; pwm <= 16; pwm++) {
                    if (!FileUtils.test("%s/pwm%d".printf(base_path, pwm), FileTest.EXISTS)
                        || !FileUtils.test("%s/pwm%d_enable".printf(base_path, pwm), FileTest.EXISTS)) {
                        continue;
                    }
                    string id = "%s-pwm%d".printf(device, pwm);
                    var ch = find(id) ?? new FanChannel();
                    ch.id = id;
                    ch.hwmon_path = base_path;
                    ch.pwm = pwm;
                    ch.chip = chip;
                    ch.driver = driver;
                    string? fan_label = read_line("%s/fan%d_label".printf(base_path, pwm));
                    ch.label = fan_label != null && fan_label != ""
                        ? "%s %s".printf(chip, fan_label)
                        : "%s fan %d".printf(chip, pwm);
                    if (!ch.probed) classify(ch);
                    found.add(ch);
                }
            }
            channels = found;
        }

        private void classify(FanChannel ch) {
            ch.probed = true;
            ch.method = "";
            ch.reason = "";
            string name = ch.driver != "" ? ch.driver : ch.chip;
            if (!(ch.driver in SOFTWARE_DRIVERS)) {
                ch.reason = "The %s driver is not a supported fan controller".printf(name);
                return;
            }
            if (ch.driver == "thinkpad_hwmon") {
                string? allowed = read_line(sysfs_root + "/sys/module/thinkpad_acpi/parameters/fan_control");
                if (allowed == null || allowed.down() != "y") {
                    ch.reason = "The kernel keeps ThinkPad fan control disabled (thinkpad_acpi fan_control=0)";
                    return;
                }
            }
            int enable = read_int(ch.enable_path, -1);
            if (enable < 0) {
                ch.reason = "The fan controller does not report its control mode";
                return;
            }
            if (!write_value(ch.enable_path, enable)) {
                ch.reason = "The kernel rejected a write to the fan controller";
                return;
            }
            ch.firmware_enable = enable >= 2 ? enable : 2;
            int points = 0;
            while (points < 16
                   && is_writable(ch.point_path(points + 1, "temp"))
                   && is_writable(ch.point_path(points + 1, "pwm"))) {
                points++;
            }
            ch.chip_points = points;
            if (ch.driver in HARDWARE_DRIVERS && points >= MIN_POINTS) {
                ch.method = "hardware";
                ch.max_points = int.min(points, MAX_POINTS);
            } else {
                ch.method = "software";
                ch.max_points = MAX_POINTS;
            }
        }

        public int crit_millidegrees() {
            sensors.refresh();
            int crit = 0;
            foreach (var reading in sensors.readings()) {
                if (reading.kind != SensorKind.CPU) continue;
                if (crit == 0 || reading.limit_millidegrees < crit) crit = reading.limit_millidegrees;
            }
            return crit > 0 ? crit : Thresholds.fallback_limit(SensorKind.CPU);
        }

        private int current_millidegrees() {
            sensors.refresh();
            if (sensors.cpu_millidegrees > 0) return sensors.cpu_millidegrees;
            return sensors.system_millidegrees;
        }

        public void validate(FanChannel ch, int[] temps, int[] percents, int crit) throws FanControlError {
            int n = temps.length;
            if (n != percents.length || n < MIN_POINTS || n > ch.max_points) {
                throw new FanControlError.INVALID_CURVE(
                    "A fan curve needs between %d and %d points".printf(MIN_POINTS, ch.max_points));
            }
            int ceiling = crit - CRIT_MARGIN_MILLIDEGREES;
            for (int i = 0; i < n; i++) {
                if (temps[i] < MIN_CURVE_MILLIDEGREES || temps[i] > ceiling) {
                    throw new FanControlError.INVALID_CURVE(
                        "Curve points must lie between %d °C and %d °C".printf(
                            MIN_CURVE_MILLIDEGREES / 1000, ceiling / 1000));
                }
                if (i > 0 && temps[i] <= temps[i - 1]) {
                    throw new FanControlError.INVALID_CURVE("Temperatures must increase from point to point");
                }
                if (percents[i] < MIN_PERCENT || percents[i] > 100) {
                    throw new FanControlError.INVALID_CURVE(
                        "Fan speed must stay between %d%% and 100%%".printf(MIN_PERCENT));
                }
                if (i > 0 && percents[i] < percents[i - 1]) {
                    throw new FanControlError.INVALID_CURVE("Fan speed must not drop as the temperature rises");
                }
            }
        }

        public static int next_percent(FanCurve curve, int millidegrees, int crit, int last_percent) {
            int target = curve.percent_at(millidegrees);
            if (millidegrees >= crit - CRIT_MARGIN_MILLIDEGREES) target = 100;
            if (target < MIN_PERCENT) target = MIN_PERCENT;
            if (target < last_percent - RAMP_DOWN_PERCENT) target = last_percent - RAMP_DOWN_PERCENT;
            return target.clamp(MIN_PERCENT, 100);
        }

        private static int to_pwm(int percent) {
            return (int) Math.round(percent * 255.0 / 100.0);
        }

        private string config_file(string name) {
            return Path.build_filename(config_dir, name);
        }

        private KeyFile load_keyfile(string path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
            }
            return kf;
        }

        private void save_keyfile(KeyFile kf, string path) {
            DirUtils.create_with_parents(Path.get_dirname(path), 0755);
            try {
                FileUtils.set_contents(path, kf.to_data());
            } catch (Error e) {
                warning("fan control: cannot write %s: %s", path, e.message);
            }
        }

        private void snapshot_firmware(FanChannel ch) {
            string path = config_file("firmware.conf");
            var kf = load_keyfile(path);
            if (kf.has_group(ch.id)) return;
            kf.set_integer(ch.id, "enable", ch.firmware_enable);
            int[] temps = {};
            int[] pwms = {};
            for (int point = 1; point <= ch.chip_points; point++) {
                temps += read_int(ch.point_path(point, "temp"), 0);
                pwms += read_int(ch.point_path(point, "pwm"), 255);
            }
            if (temps.length > 0) {
                kf.set_integer_list(ch.id, "temps", temps);
                kf.set_integer_list(ch.id, "pwms", pwms);
            }
            save_keyfile(kf, path);
        }

        private void save_curve(FanChannel ch) {
            string path = config_file("curves.conf");
            var kf = load_keyfile(path);
            if (ch.curve == null) {
                try {
                    kf.remove_group(ch.id);
                } catch (Error e) {
                }
            } else {
                kf.set_integer_list(ch.id, "temps", ch.curve.temps);
                kf.set_integer_list(ch.id, "percents", ch.curve.percents);
            }
            save_keyfile(kf, path);
        }

        private void record_manual(FanChannel ch, bool manual) {
            var kf = load_keyfile(state_path);
            if (manual) {
                kf.set_string(ch.id, "path", ch.enable_path);
                kf.set_integer(ch.id, "enable", ch.firmware_enable);
            } else {
                try {
                    kf.remove_group(ch.id);
                } catch (Error e) {
                }
            }
            save_keyfile(kf, state_path);
        }

        public static int restore_from_state(string state_path) {
            var kf = new KeyFile();
            try {
                kf.load_from_file(state_path, KeyFileFlags.NONE);
            } catch (Error e) {
                return 0;
            }
            int restored = 0;
            foreach (string group in kf.get_groups()) {
                try {
                    string path = kf.get_string(group, "path");
                    int enable = kf.get_integer(group, "enable");
                    if (write_value(path, enable >= 2 ? enable : 2)) restored++;
                } catch (Error e) {
                }
            }
            FileUtils.unlink(state_path);
            return restored;
        }

        public void apply(string id, int[] temps, int[] percents) throws FanControlError {
            touch();
            var ch = find(id);
            if (ch == null) throw new FanControlError.UNKNOWN_CHANNEL("No fan channel named %s".printf(id));
            if (ch.method == "") throw new FanControlError.UNSUPPORTED(ch.reason);
            int crit = crit_millidegrees();
            validate(ch, temps, percents, crit);
            snapshot_firmware(ch);
            var curve = new FanCurve(temps, percents);
            if (ch.method == "hardware") {
                write_hardware_curve(ch, curve, crit);
            } else {
                start_software_curve(ch, curve);
            }
            save_curve(ch);
            changed();
        }

        private void write_hardware_curve(FanChannel ch, FanCurve curve, int crit) throws FanControlError {
            int n = curve.temps.length;
            int[] temps = {};
            int[] pwms = {};
            for (int i = 0; i < ch.chip_points; i++) {
                if (i < n) {
                    temps += curve.temps[i];
                    pwms += to_pwm(curve.percents[i]);
                } else {
                    temps += int.min(curve.temps[n - 1] + (i - n + 1) * 1000, crit);
                    pwms += 255;
                }
            }
            bool ok = true;
            for (int i = 0; i < ch.chip_points && ok; i++) {
                ok = write_value(ch.point_path(i + 1, "temp"), temps[i])
                    && write_value(ch.point_path(i + 1, "pwm"), pwms[i]);
            }
            ok = ok && write_value(ch.enable_path, HARDWARE_CURVE_ENABLE);
            for (int i = 0; i < ch.chip_points && ok; i++) {
                ok = (read_int(ch.point_path(i + 1, "temp"), -1) - temps[i]).abs() <= 1000
                    && (read_int(ch.point_path(i + 1, "pwm"), -1) - pwms[i]).abs() <= 4;
            }
            ok = ok && read_int(ch.enable_path, -1) == HARDWARE_CURVE_ENABLE;
            if (!ok) {
                restore_firmware_snapshot(ch);
                throw new FanControlError.WRITE_FAILED("The fan chip did not accept the curve; firmware control was restored");
            }
            ch.curve = curve;
            ch.active = "hardware";
        }

        private void start_software_curve(FanChannel ch, FanCurve curve) throws FanControlError {
            record_manual(ch, true);
            if (!write_value(ch.enable_path, 1)) {
                record_manual(ch, false);
                throw new FanControlError.WRITE_FAILED("The fan controller refused manual mode");
            }
            ch.curve = curve;
            ch.active = "software";
            ch.last_percent = 100;
            drive(ch, current_millidegrees(), crit_millidegrees());
        }

        private void drive(FanChannel ch, int millidegrees, int crit) {
            if (millidegrees <= 0) {
                release(ch);
                warning("fan control: no temperature reading, %s handed back to firmware", ch.id);
                return;
            }
            int percent = next_percent(ch.curve, millidegrees, crit, ch.last_percent);
            if (!write_value(ch.pwm_path, to_pwm(percent))) {
                release(ch);
                warning("fan control: cannot write %s, handed back to firmware", ch.pwm_path);
                return;
            }
            ch.last_percent = percent;
        }

        public void tick() {
            if (!has_software_curves()) return;
            int millidegrees = current_millidegrees();
            int crit = crit_millidegrees();
            bool dropped = false;
            foreach (var ch in channels) {
                if (ch.active != "software") continue;
                if (read_int(ch.enable_path, -1) != 1) {
                    ch.active = "firmware";
                    record_manual(ch, false);
                    dropped = true;
                    continue;
                }
                drive(ch, millidegrees, crit);
                if (ch.active != "software") dropped = true;
            }
            if (dropped) changed();
        }

        private void release(FanChannel ch) {
            write_value(ch.enable_path, ch.firmware_enable);
            ch.active = "firmware";
            record_manual(ch, false);
        }

        public void release_all() {
            bool any = false;
            foreach (var ch in channels) {
                if (ch.active != "software") continue;
                release(ch);
                any = true;
            }
            if (any) changed();
        }

        public void resume() {
            Timeout.add_seconds(RESUME_SETTLE_SECONDS, () => {
                reapply_saved();
                return Source.REMOVE;
            });
        }

        private void restore_firmware_snapshot(FanChannel ch) {
            var kf = load_keyfile(config_file("firmware.conf"));
            if (kf.has_group(ch.id)) {
                try {
                    if (kf.has_key(ch.id, "temps")) {
                        int[] temps = kf.get_integer_list(ch.id, "temps");
                        int[] pwms = kf.get_integer_list(ch.id, "pwms");
                        for (int i = 0; i < temps.length && i < pwms.length; i++) {
                            write_value(ch.point_path(i + 1, "temp"), temps[i]);
                            write_value(ch.point_path(i + 1, "pwm"), pwms[i]);
                        }
                    }
                    ch.firmware_enable = kf.get_integer(ch.id, "enable");
                } catch (Error e) {
                }
            }
            write_value(ch.enable_path, ch.firmware_enable >= 2 ? ch.firmware_enable : 2);
        }

        public void reset(string id) throws FanControlError {
            touch();
            var ch = find(id);
            if (ch == null) throw new FanControlError.UNKNOWN_CHANNEL("No fan channel named %s".printf(id));
            if (ch.method == "") throw new FanControlError.UNSUPPORTED(ch.reason);
            if (ch.active == "software") release(ch);
            restore_firmware_snapshot(ch);
            ch.curve = null;
            ch.active = "firmware";
            save_curve(ch);
            changed();
        }

        public void reapply_saved() {
            var kf = load_keyfile(config_file("curves.conf"));
            foreach (var ch in channels) {
                if (ch.method == "" || !kf.has_group(ch.id)) continue;
                try {
                    int[] temps = kf.get_integer_list(ch.id, "temps");
                    int[] percents = kf.get_integer_list(ch.id, "percents");
                    apply(ch.id, temps, percents);
                } catch (Error e) {
                    warning("fan control: cannot restore the saved curve for %s: %s", ch.id, e.message);
                }
            }
        }

        public HashTable<string, Variant>[] describe() {
            scan();
            int crit = crit_millidegrees();
            HashTable<string, Variant>[] result = {};
            foreach (var ch in channels) {
                var dict = new HashTable<string, Variant>(str_hash, str_equal);
                dict["id"] = ch.id;
                dict["hwmon"] = Path.get_basename(ch.hwmon_path);
                dict["pwm"] = ch.pwm;
                dict["label"] = ch.label;
                dict["method"] = ch.method;
                dict["active"] = ch.active;
                dict["reason"] = ch.reason;
                dict["crit"] = crit;
                dict["min_percent"] = MIN_PERCENT;
                dict["max_points"] = ch.max_points;
                int[] temps = {};
                int[] percents = {};
                if (ch.curve != null) {
                    temps = ch.curve.temps;
                    percents = ch.curve.percents;
                } else if (ch.method == "hardware") {
                    for (int point = 1; point <= ch.max_points; point++) {
                        temps += read_int(ch.point_path(point, "temp"), 0);
                        percents += (int) Math.round(read_int(ch.point_path(point, "pwm"), 255) * 100.0 / 255.0);
                    }
                }
                dict["temps"] = temps;
                dict["percents"] = percents;
                result += dict;
            }
            return result;
        }
    }
}
