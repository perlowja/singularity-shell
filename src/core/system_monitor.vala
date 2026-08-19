namespace Singularity {

    public class SystemMonitor : Object {
        private static SystemMonitor? _instance;

        public PowerManager power { get { if (_power == null) _power = new PowerManager(); return _power; } }
        public NetworkManagerWrapper network { get { if (_network == null) _network = new NetworkManagerWrapper(); return _network; } }
        public AudioManager audio { get { if (_audio == null) _audio = new AudioManager(); return _audio; } }
        public BrightnessManager brightness { get { if (_brightness == null) _brightness = new BrightnessManager(); return _brightness; } }
        public KbdBrightnessManager kbd_brightness { get { if (_kbd_brightness == null) _kbd_brightness = new KbdBrightnessManager(); return _kbd_brightness; } }
        public NightLightManager night_light { get { if (_night_light == null) { _night_light = new NightLightManager(); _night_light.backend = new WaylandGammaBackend(); } return _night_light; } }
        public ShortcutManager shortcuts { get { if (_shortcuts == null) _shortcuts = new ShortcutManager(); return _shortcuts; } }
        public NotificationManager notifications { get { if (_notifications == null) _notifications = new NotificationManager(); return _notifications; } }
        public DateTimeManager datetime { get { if (_datetime == null) _datetime = new DateTimeManager(); return _datetime; } }
        public LocaleManager locale { get { if (_locale == null) _locale = new LocaleManager(); return _locale; } }
        public BluetoothManager bluetooth { get { if (_bluetooth == null) _bluetooth = new BluetoothManager(); return _bluetooth; } }
        public PowerProfilesManager power_profiles { get { if (_power_profiles == null) _power_profiles = new PowerProfilesManager(); return _power_profiles; } }
        public ResourceMonitor resources { get { if (_resources == null) _resources = new ResourceMonitor(); return _resources; } }
        /**
         * Sensors, with the CIX Sky1 naming hints applied.
         *
         * MEASURED 2026-08-16 on two Sky1 machines that present COMPLETELY
         * DIFFERENT sensor topologies, decided by one kernel command line flag:
         *
         *   cixmini, 7.0.12-cix-sky1-next, no acpi_scmi_en flag
         *       -> one hwmon chip "scmi_sensors" carrying 22 LABELLED sensors
         *          (CPU_B0, CPU_M1, GPU_AVE, NPU, VPU, DDR_top, PCB_AMB, ...)
         *
         *   O6N,     7.2.0-rc7-sky1-ncz,    acpi_scmi_en=off
         *       -> no scmi_sensors at all; five bare ACPI thermal zones named
         *          TZB0 TZB1 TZM0 TZM1 TZGT, with NO labels and no tempN_crit
         *
         * We disable SCMI on 7.2 deliberately, so the shipping configuration is
         * the second one. There the allow-lists in SensorMonitor cannot help --
         * the identity is in a four-character ACPI name and nowhere else -- and
         * the panel reported cpu=-1 gpu=-1 on the board this product targets.
         *
         * TZB = big cluster, TZM = mid cluster, TZGT = graphics. gpu_hint is
         * tested before cpu_hint by SensorMonitor.classify(), so the more
         * specific TZGT claims the GPU before the broader TZ claims the rest.
         * Verified on O6N: cpu=49000 gpu=46000, with nvme and both r8169 NICs
         * still correctly SYSTEM. Both hints are inert on the scmi_sensors
         * topology, where no chip or label contains "TZ", so one configuration
         * serves both kernels.
         */
        /**
         * Live CPU / memory / disk utilisation.
         *
         * Separate from `sensors` because it needs start/stop for CORRECTNESS,
         * not merely to save power: every figure but memory is a rate computed
         * between two samples, so a monitor left running while nothing reads
         * it is measuring a window no one asked about.
         */
        public UtilizationMonitor utilization {
            get {
                if (_utilization == null) {
                    _utilization = new UtilizationMonitor();
                }
                return _utilization;
            }
        }

        public SensorMonitor sensors {
            get {
                if (_sensors == null) {
                    _sensors = new SensorMonitor();
                    // Scope these to the hardware they were measured on.
                    //
                    // These are four-character ACPI names specific to the CIX
                    // Sky1 topology, not general heuristics, so applying them
                    // on every platform makes a Sky1 quirk everyone else's
                    // problem. The substring match is case-sensitive, so the
                    // lowercase x86 "acpitz" chip does not in fact collide
                    // with "TZ" -- but relying on that is a coincidence, not
                    // a design, and it would break the moment any platform
                    // exposed an uppercase label containing TZ. Gate on the
                    // actual board instead: inert everywhere else by
                    // construction rather than by luck.
                    if (is_cix_sky1()) {
                        _sensors.gpu_hint = "TZGT";
                        _sensors.cpu_hint = "TZ";
                    }
                }
                return _sensors;
            }
        }

        /**
         * True on CIX Sky1 boards (Radxa Orion O6/O6N, cixmini).
         *
         * Detects the SoC by its own ACPI hardware IDs rather than by board
         * branding. MEASURED on an O6N running the shipping ACPI kernel:
         * there is no devicetree at all, and every DMI vendor/product string
         * says "Radxa ... Orion O6N" -- not "CIX" and not "Sky1" -- so a
         * vendor-string match reports FALSE on the exact hardware these
         * hints exist for, silently restoring the cpu=-1/gpu=-1 bug they
         * were added to fix. The CIXH* HIDs are the SoC's, not the board
         * vendor's: 163 of them enumerate on that same machine. Devicetree
         * is still checked so a DT-booted Sky1 is covered too.
         */
        private static bool is_cix_sky1() {
            try {
                Dir acpi = Dir.open("/sys/bus/acpi/devices", 0);
                string? name;
                while ((name = acpi.read_name()) != null) {
                    if (name.has_prefix("CIXH")) {
                        return true;
                    }
                }
            } catch (FileError e) {
                // No ACPI bus (a DT-only kernel); fall through.
            }

            string[] dt_probes = {
                "/proc/device-tree/compatible",
                "/sys/firmware/devicetree/base/compatible",
            };
            foreach (string path in dt_probes) {
                // "compatible" is a NUL-SEPARATED list, conventionally most
                // specific first: "radxa,<board>\0cix,sky1". Reading it into a
                // Vala string and matching that stops at the first NUL, so
                // only the board entry is ever examined and the "cix,sky1"
                // that identifies the SoC is missed -- on precisely the
                // DT-booted configuration this fallback exists to catch.
                // load_contents() returns the real byte array, so every entry
                // is inspected.
                uint8[] raw;
                try {
                    if (!File.new_for_path(path).load_contents(null, out raw, null)) {
                        continue;
                    }
                } catch (Error e) {
                    continue;
                }
                var joined = new StringBuilder();
                foreach (uint8 b in raw) {
                    joined.append_c(b == 0 ? ' ' : (char) b);
                }
                string lowered = joined.str.down();
                if (lowered.contains("cix") || lowered.contains("sky1")) {
                    return true;
                }
            }
            return false;
        }
        public CallMonitor call_monitor { get { if (_call_monitor == null) _call_monitor = new CallMonitor(audio); return _call_monitor; } }

        private PowerManager? _power;
        private NetworkManagerWrapper? _network;
        private AudioManager? _audio;
        private BrightnessManager? _brightness;
        private KbdBrightnessManager? _kbd_brightness;
        private NightLightManager? _night_light;
        private ShortcutManager? _shortcuts;
        private NotificationManager? _notifications;
        private DateTimeManager? _datetime;
        private LocaleManager? _locale;
        private BluetoothManager? _bluetooth;
        private PowerProfilesManager? _power_profiles;
        private ResourceMonitor? _resources;
        private SensorMonitor? _sensors = null;
        private UtilizationMonitor? _utilization = null;
        private CallMonitor? _call_monitor;

        public static SystemMonitor get_default() {
            if (_instance == null) {
                _instance = new SystemMonitor();
            }
            return _instance;
        }

        private SystemMonitor() {
        }
    }
}