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
        public SensorMonitor sensors {
            get {
                if (_sensors == null) {
                    _sensors = new SensorMonitor();
                    _sensors.gpu_hint = "TZGT";
                    _sensors.cpu_hint = "TZ";
                }
                return _sensors;
            }
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