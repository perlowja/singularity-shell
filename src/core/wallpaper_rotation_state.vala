using GLib;

namespace Singularity {

    public class WallpaperRotationState : Object {
        private const int DEFAULT_INTERVAL_SECONDS = 600;
        private const int MIN_INTERVAL_SECONDS = 30;

        private string config_dir;

        public WallpaperRotationState(string config_dir) {
            this.config_dir = config_dir;
        }

        public static string default_config_dir() {
            return GLib.Path.build_filename(
                GLib.Environment.get_user_config_dir(), "singularity", "wallpaper-rotation");
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
            string dest = path_for(filename);
            string tmp = dest + ".tmp";
            try {
                // Same-directory rename keeps state updates atomic for readers.
                FileUtils.set_contents(tmp, contents);
                if (FileUtils.rename(tmp, dest) != 0) {
                    warning("wallpaper rotation state: could not rename %s into place", filename);
                }
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

        // Rotation is opt-in; an absent state file must remain off.
        public bool get_rotate_enabled() {
            string? value = read_trimmed("rotate-enabled");
            if (value == null) return false;
            string lowered = value.down();
            return lowered != "0" && lowered != "false" && lowered != "off";
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
