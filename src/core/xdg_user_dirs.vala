using GLib;

namespace Singularity {

    public class XdgUserDirs : Object {
        private XdgUserDirs() {}

        public static string? desktop_dir() {
            string? configured = Environment.get_user_special_dir(UserDirectory.DESKTOP);
            string dir;
            if (configured != null && configured.strip() != "") {
                dir = configured;
            } else {
                dir = Path.build_filename(Environment.get_home_dir(), "Desktop");
            }

            if (File.new_for_path(dir).equal(File.new_for_path(Environment.get_home_dir()))) {
                return null;
            }

            return dir;
        }
    }
}
