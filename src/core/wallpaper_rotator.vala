using GLib;
using Gee;

namespace Singularity {

    // The runtime consumer of the rotation-state files the Desktop settings
    // page writes (see WallpaperRotationState for the file format). Without
    // something on this side actually reading them, "Rotate Wallpapers" and
    // "Rotation Interval" are inert controls: they persist a preference
    // nothing acts on.
    //
    // WHY THIS LIVES IN THE SHELL PROCESS RATHER THAN A SEPARATE DAEMON.
    // The shell is already running for the whole session, already owns the
    // wallpaper through WallpaperManager, and already repaints it on a
    // GSettings change -- so rotation here is a timer plus a settings write,
    // and the crossfade, rescaling and accent extraction are reused
    // unchanged. A separate binary would need a second copy of the
    // collection parsing, its own GSettings schema lookup against whatever
    // prefix the shell was installed into, and a session unit or autostart
    // entry that actually gets started -- which is the part that tends to
    // fail silently, leaving a rotator that is installed, correct, and has
    // never once run. None of that buys anything the shell cannot already
    // do, so it is not a daemon or a new IPC surface.
    //
    // Policy only: this class decides WHICH image and WHEN, and announces it
    // through wallpaper_selected. It never touches GSettings, GTK or Gdk
    // itself -- WallpaperManager.start_rotation() is the one place the
    // decision is turned into an applied wallpaper, which is also what keeps
    // this testable against temporary directories with no session at all.
    public class WallpaperRotator : Object {
        private static WallpaperRotator? _instance = null;
        private const int FAVORITE_WEIGHT = 3; // Noticeable bias without starving new images.
        private const double ASPECT_TOLERANCE = 0.15;

        // The chosen wallpaper, as a file:// URI. Connect to apply it.
        public signal void wallpaper_selected(string uri);

        // What is on screen right now, so a rotation does not "change" the
        // wallpaper to the one already showing. Kept in sync by whoever
        // applies the signal, because the wallpaper can also be changed from
        // the gallery or another application while the timer is armed.
        public string? current_uri { get; set; default = null; }

        // What the armed timer is actually set to, or 0 when rotation is off.
        // Observable so "the switch is off" and "the interval changed" are
        // assertable without a test that waits out a real rotation period.
        public int armed_interval_seconds { get; private set; default = 0; }

        private WallpaperRotationState state;
        private string[] collection_roots;
        private string config_dir;
        private uint tick_id = 0;
        private uint restart_id = 0;
        private FileMonitor? state_monitor = null;
        private GLib.Settings? selection_settings = null;
        private WallpaperFavorites? favorites = null;
        private int test_min_width = 1280;
        private int test_min_height = 720;
        private bool test_match_aspect = false;
        private bool test_favor_favorites = true;
        public double target_aspect_ratio { get; set; default = 0.0; }

        public static WallpaperRotator get_default() {
            if (_instance == null) {
                _instance = new WallpaperRotator(
                    WallpaperRotationState.default_config_dir(),
                    WallpaperCollections.default_search_roots());
                _instance.selection_settings = new GLib.Settings("dev.sinty.desktop");
                _instance.favorites = new WallpaperFavorites(_instance.selection_settings);
            }
            return _instance;
        }

        // config_dir and collection_roots are injected rather than read from
        // GLib.Environment here, matching WallpaperRotationState and
        // WallpaperCollections, so the rotation policy is testable against a
        // temp directory.
        public WallpaperRotator(string config_dir, string[] collection_roots) {
            this.config_dir = config_dir;
            this.collection_roots = collection_roots;
            this.state = new WallpaperRotationState(config_dir);
        }

        // Tests inject policy directly; production reads the matching
        // GSettings keys for every pick so changes take effect immediately.
        public void configure_selection(int min_width, int min_height,
                                        bool match_aspect, bool favor_favorites,
                                        double target_aspect = 0.0,
                                        WallpaperFavorites? favorites = null) {
            test_min_width = min_width;
            test_min_height = min_height;
            test_match_aspect = match_aspect;
            test_favor_favorites = favor_favorites;
            target_aspect_ratio = target_aspect;
            this.favorites = favorites;
        }

        // Arms the timer and starts watching the state files. Safe to call
        // more than once; a second call just re-reads the state.
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
                // Cancel, not just drop: the monitor's "changed" handler holds
                // a reference back to this object, so releasing the field is
                // not on its own enough to stop events arriving.
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

        // Re-read rotate-enabled / rotate-interval and arm (or cancel) the
        // timer accordingly. The interval is read at arm time rather than
        // cached at startup, so a user who changes it does not have to log
        // out for the new value to take effect.
        public void reschedule() {
            cancel_tick();
            if (!state.get_rotate_enabled()) return;
            int interval = state.get_rotate_interval_seconds();
            armed_interval_seconds = interval;
            tick_id = Timeout.add_seconds(interval, () => {
                tick_id = 0;
                armed_interval_seconds = 0;
                // Re-check enabled at fire time as well: the file can have
                // been written after this timer was armed by something that
                // does not go through the settings page.
                if (state.get_rotate_enabled()) rotate_async();
                reschedule();
                return Source.REMOVE;
            });
        }

        // What the timer fires. choose_next() walks the collection directory
        // and queries a content type per file, which is filesystem I/O this
        // process must not do on the main loop -- it is the compositor's, and
        // a stall there drops frames. populate_grid() in the settings page
        // threads the identical scan for the same reason. Public because this,
        // not rotate_now(), is the path every real rotation takes, and a path
        // no test can reach is a path nothing checks.
        public void rotate_async() {
            // Snapshot on the main thread: current_uri is written here when
            // the wallpaper changes, and the worker must not read the
            // property concurrently.
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

        // Pick an image from the selected collection and announce it, on the
        // calling thread. Public so a future "Next wallpaper" action has
        // something to call, and so the tests can drive one rotation without
        // a timer or a main loop.
        public void rotate_now() {
            string? uri = choose_next();
            if (uri == null) return;
            current_uri = uri;
            wallpaper_selected(uri);
        }

        // The whole decision, with no side effects, so it can be asserted on
        // directly: which collection, which images are in it, and which one
        // is next. Returns null when there is nothing to rotate to -- an
        // empty pack, a provider that fetched nothing, a stale collection id
        // -- in which case the desktop keeps the wallpaper it has rather
        // than being left with none.
        public string? choose_next() {
            return choose_next_for(current_uri);
        }

        // The wallpaper to avoid is passed in rather than read from the
        // property, so the worker thread in rotate_async() works from a
        // main-thread snapshot instead of racing a concurrent write to it.
        public string? choose_next_for(string? current) {
            var collections = WallpaperCollections.parse(collection_roots);
            if (collections.size == 0) return null;

            string selected_id = state.get_selected_collection("");
            string? scan_dir = null;
            foreach (var collection in collections) {
                if (collection.id == selected_id) { scan_dir = collection.dir; break; }
            }
            // Same fallback the gallery makes for a deleted pack or a stale
            // state file: use the first known collection rather than doing
            // nothing. Not persisted here -- the settings page owns that
            // file, and a background timer quietly rewriting the user's
            // selection is not the rotator's business.
            if (scan_dir == null) scan_dir = collections[0].dir;

            var all_dirs = new ArrayList<string>();
            foreach (var collection in collections) all_dirs.add(collection.dir);

            // No "recent" ordering: recency is a gallery presentation
            // concern, and passing it here would bias the rotation toward
            // the images the user has most recently picked by hand.
            var candidates = WallpaperGallery.scan(scan_dir, all_dirs.to_array(), {});
            if (candidates.size == 0) return null;

            int min_width = setting_int("wallpaper-rotation-min-width", test_min_width);
            int min_height = setting_int("wallpaper-rotation-min-height", test_min_height);
            bool match_aspect = setting_bool("wallpaper-rotation-match-aspect", test_match_aspect);
            bool favor_favorites = setting_bool("wallpaper-rotation-favor-favorites", test_favor_favorites);
            var regarded = regard(candidates, min_width, min_height,
                                  match_aspect, target_aspect_ratio);
            return pick_candidates(regarded, current, Random.next_int(),
                                   favor_favorites, favorites);
        }

        private int setting_int(string key, int fallback) {
            if (selection_settings == null || !selection_settings.settings_schema.has_key(key)) return fallback;
            return selection_settings.get_int(key);
        }

        private bool setting_bool(string key, bool fallback) {
            if (selection_settings == null || !selection_settings.settings_schema.has_key(key)) return fallback;
            return selection_settings.get_boolean(key);
        }

        internal static ArrayList<WallpaperCandidate> regard(
                Gee.List<WallpaperCandidate> candidates, int min_width, int min_height,
                bool match_aspect, double target_aspect) {
            var sized = new ArrayList<WallpaperCandidate>();
            foreach (var candidate in candidates) {
                if (candidate.width >= min_width && candidate.height >= min_height)
                    sized.add(candidate);
            }
            if (sized.size == 0 && candidates.size > 0) {
                debug("wallpaper rotator: minimum resolution excluded every candidate; using unfiltered collection");
                foreach (var candidate in candidates) sized.add(candidate);
            }
            if (!match_aspect || target_aspect <= 0.0) return sized;

            var matched = new ArrayList<WallpaperCandidate>();
            foreach (var candidate in sized) {
                if (candidate.width <= 0 || candidate.height <= 0) continue;
                double aspect = (double) candidate.width / (double) candidate.height;
                if (Math.fabs(aspect - target_aspect) / target_aspect <= ASPECT_TOLERANCE)
                    matched.add(candidate);
            }
            if (matched.size == 0) {
                debug("wallpaper rotator: aspect preference matched no candidates; using resolution-filtered collection");
                return sized;
            }
            return matched;
        }

        internal static string? pick_candidates(Gee.List<WallpaperCandidate> candidates,
                                                string? current_uri, uint32 roll,
                                                bool favor_favorites,
                                                WallpaperFavorites? favorites) {
            var choices = new ArrayList<WallpaperCandidate>();
            foreach (var candidate in candidates) {
                if (candidates.size == 1 || candidate.uri != current_uri) choices.add(candidate);
            }
            if (choices.size == 0) return candidates.size > 0 ? candidates[0].uri : null;

            int total_weight = 0;
            foreach (var candidate in choices) {
                string? path = File.new_for_uri(candidate.uri).get_path();
                bool favorite = favor_favorites && favorites != null && path != null
                    && favorites.is_favorite(path);
                total_weight += favorite ? FAVORITE_WEIGHT : 1;
            }
            int selected = (int) (roll % total_weight);
            foreach (var candidate in choices) {
                string? path = File.new_for_uri(candidate.uri).get_path();
                bool favorite = favor_favorites && favorites != null && path != null
                    && favorites.is_favorite(path);
                int weight = favorite ? FAVORITE_WEIGHT : 1;
                if (selected < weight) return candidate.uri;
                selected -= weight;
            }
            return choices[0].uri;
        }

        // Random, but never the image already on screen when the collection
        // has an alternative -- a rotation that lands on the current
        // wallpaper looks like the feature is broken. Taking the roll as a
        // parameter keeps this deterministic under test instead of making
        // the suite depend on a random draw.
        public static string? pick(Gee.List<string> uris, string? current_uri, uint32 roll) {
            if (uris.size == 0) return null;
            if (uris.size == 1) return uris[0];

            var choices = new ArrayList<string>();
            foreach (string uri in uris) {
                if (uri != current_uri) choices.add(uri);
            }
            // Every candidate equals the current one (a collection of
            // duplicates): keep what is showing rather than return null,
            // which the caller would read as "nothing to rotate to".
            if (choices.size == 0) return uris[0];
            return choices[(int) (roll % choices.size)];
        }

        // The state files are a documented, project-owned contract, so the
        // settings page is not assumed to be the only writer: watch the
        // directory instead of having the UI call back into here. That also
        // means an interval change applies immediately rather than after the
        // current (possibly day-long) period elapses.
        private void watch_state_dir() {
            if (state_monitor != null) return;
            DirUtils.create_with_parents(config_dir, 0700);
            try {
                var dir = File.new_for_path(config_dir);
                state_monitor = dir.monitor_directory(FileMonitorFlags.NONE, null);
            } catch (Error e) {
                // Not fatal: without a monitor the timer still re-reads the
                // state on every tick, so changes take effect one period
                // late instead of immediately.
                warning("wallpaper rotator: cannot watch %s: %s", config_dir, e.message);
                return;
            }
            state_monitor.changed.connect((file, other, event) => {
                // WallpaperRotationState writes through a temp file and
                // renames it into place, so a single logical change arrives
                // as several events. Coalesce them, or each write re-arms the
                // timer two or three times.
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
