namespace Singularity.Compositor {

    /**
     * Centralises all interaction with the labwc compositor: where its config
     * lives, how config files are written, and how it is asked to reload.
     *
     * The shell used to scatter labwc specifics (the ~/.config/labwc path, the
     * binary resolution, the "labwc -r" reload) across main.vala, the shortcut
     * manager, the display manager and the command palette, each doing it a little
     * differently. Routing everything through this single backend keeps the rest
     * of the shell free of compositor details and is the natural seam at which a
     * different compositor could be swapped in later.
     */
    public class LabwcBackend : Object {

        private static LabwcBackend? _instance;

        /** Returns the shared backend, creating it on first call. */
        public static LabwcBackend get_default() {
            if (_instance == null) {
                _instance = new LabwcBackend();
            }
            return _instance;
        }

        /** Absolute path to the labwc config directory, created if missing. */
        public string config_dir() {
            string dir = GLib.Path.build_filename(
                GLib.Environment.get_home_dir(), ".config", "labwc");
            GLib.DirUtils.create_with_parents(dir, 0755);
            return dir;
        }

        /** Absolute path to a file inside the labwc config directory. */
        public string config_path(string filename) {
            return GLib.Path.build_filename(config_dir(), filename);
        }

        /**
         * Writes a labwc config file, skipping the write when the contents are
         * already up to date.
         *
         * @return true if the file changed and was written, false if it was
         *         already current (or the write failed).
         */
        public bool write_config(string filename, string contents) {
            string path = config_path(filename);
            string? existing = null;
            try { GLib.FileUtils.get_contents(path, out existing); } catch { }
            if (existing != null && existing == contents) {
                return false;
            }
            try {
                GLib.FileUtils.set_contents(path, contents);
            } catch (GLib.Error e) {
                warning("LabwcBackend: failed to write %s: %s", path, e.message);
                return false;
            }
            return true;
        }

        /**
         * Resolves the labwc binary next to our own executable (covering the
         * install prefix), falling back to PATH.
         */
        public string binary() {
            return AppSystem.resolve_companion_bin("labwc");
        }

        /** Asks the running labwc to reload its configuration. */
        public void reconfigure() {
            try {
                Process.spawn_command_line_async("%s -r".printf(binary()));
            } catch (Error e) {
                warning("LabwcBackend: failed to reconfigure: %s", e.message);
            }
        }
    }
}
