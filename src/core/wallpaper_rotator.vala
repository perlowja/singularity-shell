using GLib;
using Gee;

namespace Singularity {

    // Selects rotation timing and images; WallpaperManager applies the signal.
    public class WallpaperRotator : Object {
        private static WallpaperRotator? _instance = null;

        public signal void wallpaper_selected(string uri);

        public string? current_uri { get; set; default = null; }

        public int armed_interval_seconds { get; private set; default = 0; }

        private WallpaperRotationState state;
        private string[] collection_roots;
        private string config_dir;
        private uint tick_id = 0;
        private uint restart_id = 0;
        private FileMonitor? state_monitor = null;

        public static WallpaperRotator get_default() {
            if (_instance == null) {
                _instance = new WallpaperRotator(
                    WallpaperRotationState.default_config_dir(),
                    WallpaperCollections.default_search_roots());
            }
            return _instance;
        }

        public WallpaperRotator(string config_dir, string[] collection_roots) {
            this.config_dir = config_dir;
            this.collection_roots = collection_roots;
            this.state = new WallpaperRotationState(config_dir);
        }

        public void start() {
            watch_state_dir();
            reschedule();
        }

        public void stop() {
            cancel_tick();
            if (restart_id != 0) {
                Source.remove(restart_id);
                restart_id = 0;
            }
            if (state_monitor != null) {
                // The signal handler retains this object until the monitor is cancelled.
                state_monitor.cancel();
                state_monitor = null;
            }
        }

        private void cancel_tick() {
            if (tick_id != 0) {
                Source.remove(tick_id);
                tick_id = 0;
            }
            armed_interval_seconds = 0;
        }

        public void reschedule() {
            cancel_tick();
            if (!state.get_rotate_enabled()) return;
            int interval = state.get_rotate_interval_seconds();
            armed_interval_seconds = interval;
            tick_id = Timeout.add_seconds(interval, () => {
                tick_id = 0;
                armed_interval_seconds = 0;
                // Another process may disable rotation after this timer is armed.
                if (state.get_rotate_enabled()) rotate_async();
                reschedule();
                return Source.REMOVE;
            });
        }

        // Keep collection scanning off the compositor's main loop.
        public void rotate_async() {
            // Snapshot before entering the worker to avoid a concurrent property read.
            string? current = current_uri;
            new Thread<void>("wallpaper-rotate", () => {
                string? uri = choose_next_for(current);
                if (uri == null) return;
                Idle.add(() => {
                    current_uri = uri;
                    wallpaper_selected(uri);
                    return Source.REMOVE;
                });
            });
        }

        public void rotate_now() {
            string? uri = choose_next();
            if (uri == null) return;
            current_uri = uri;
            wallpaper_selected(uri);
        }

        public string? choose_next() {
            return choose_next_for(current_uri);
        }

        public string? choose_next_for(string? current) {
            var collections = WallpaperCollections.parse(collection_roots);
            if (collections.size == 0) return null;

            string selected_id = state.get_selected_collection("");
            string? scan_dir = null;
            foreach (var collection in collections) {
                if (collection.id == selected_id) { scan_dir = collection.dir; break; }
            }
            // Do not let the background timer rewrite a stale user selection.
            if (scan_dir == null) scan_dir = collections[0].dir;

            var all_dirs = new ArrayList<string>();
            foreach (var collection in collections) all_dirs.add(collection.dir);

            // Recency is gallery presentation state, not rotation weighting.
            var candidates = WallpaperGallery.scan(scan_dir, all_dirs.to_array(), {});
            if (candidates.size == 0) return null;

            var uris = new ArrayList<string>();
            foreach (var candidate in candidates) uris.add(candidate.uri);
            return pick(uris, current, Random.next_int());
        }

        // Inject the random roll so selection remains deterministic in tests.
        public static string? pick(Gee.List<string> uris, string? current_uri, uint32 roll) {
            if (uris.size == 0) return null;
            if (uris.size == 1) return uris[0];

            var choices = new ArrayList<string>();
            foreach (string uri in uris) {
                if (uri != current_uri) choices.add(uri);
            }
            // A collection may contain duplicate URIs for the current image.
            if (choices.size == 0) return uris[0];
            return choices[(int) (roll % choices.size)];
        }

        // State may be written outside the settings page, so watch the directory.
        private void watch_state_dir() {
            if (state_monitor != null) return;
            DirUtils.create_with_parents(config_dir, 0700);
            try {
                var dir = File.new_for_path(config_dir);
                state_monitor = dir.monitor_directory(FileMonitorFlags.NONE, null);
            } catch (Error e) {
                // The timer still re-reads state if monitoring is unavailable.
                warning("wallpaper rotator: cannot watch %s: %s", config_dir, e.message);
                return;
            }
            state_monitor.changed.connect((file, other, event) => {
                // Atomic replacement emits multiple events; coalesce them.
                if (restart_id != 0) return;
                restart_id = Timeout.add(250, () => {
                    restart_id = 0;
                    reschedule();
                    return Source.REMOVE;
                });
            });
        }
    }
}
