using GLib;
using Gee;
using Json;

namespace Singularity {

    public class ArtistPackInfo : GLib.Object {
        public string package { get; private set; }
        public string title { get; private set; }
        public string summary { get; private set; }
        public string version { get; private set; }
        public string source { get; private set; }
        public bool installed { get; set; }

        public ArtistPackInfo(string package, string title, string summary,
                               string version, string source, bool installed) {
            this.package = package;
            this.title = title;
            this.summary = summary;
            this.version = version;
            this.source = source;
            this.installed = installed;
        }
    }

    public errordomain ArtistPackError {
        BACKEND_MISSING,
        BACKEND_FAILED,
        INVALID_RESPONSE,
    }

    public class ArtistPackManager : GLib.Object {
        private static ArtistPackManager? _instance = null;

        // Never resolved via PATH: INSTALL_HELPER is what pkexec runs as root,
        // so a PATH lookup would let ~/.local/bin shadow it and get elevated.
        private const string INVENTORY_HELPER = "/usr/local/bin/singularity-artist-pack-inventory";
        private const string INSTALL_HELPER = "/usr/local/bin/singularity-artist-pack-install";
        private const string INSTALL_POLICY = "/usr/share/polkit-1/actions/dev.sinty.desktop.artist-pack-install.policy";
        private const string[] PKEXEC_PATHS = { "/usr/bin/pkexec", "/bin/pkexec" };

        public static ArtistPackManager get_default() {
            if (_instance == null) _instance = new ArtistPackManager();
            return _instance;
        }

        private ArtistPackManager() { }

        private static bool is_executable_file(string path) {
            return FileUtils.test(path, FileTest.IS_REGULAR)
                && FileUtils.test(path, FileTest.IS_EXECUTABLE);
        }

        private static string? find_pkexec() {
            foreach (unowned string candidate in PKEXEC_PATHS) {
                if (is_executable_file(candidate)) return candidate;
            }
            return null;
        }

        // Every piece of the contract, so an incomplete backend shows nothing.
        public bool is_available() {
            return is_executable_file(INVENTORY_HELPER)
                && is_executable_file(INSTALL_HELPER)
                && FileUtils.test(INSTALL_POLICY, FileTest.IS_REGULAR)
                && find_pkexec() != null;
        }

        // Absent backend yields an empty list, not an error.
        public async Gee.ArrayList<ArtistPackInfo> fetch_inventory_async(Cancellable? cancellable = null) throws Error {
            var results = new Gee.ArrayList<ArtistPackInfo>();
            if (!is_executable_file(INVENTORY_HELPER)) return results;

            var proc = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                                       INVENTORY_HELPER);
            string stdout_data;
            string stderr_data;
            yield proc.communicate_utf8_async(null, cancellable, out stdout_data, out stderr_data);
            if (!proc.get_successful()) {
                throw new ArtistPackError.BACKEND_FAILED(
                    "%s exited with an error: %s".printf(INVENTORY_HELPER, (stderr_data ?? "").strip()));
            }
            if (stdout_data == null || stdout_data.strip().length == 0) return results;

            var parser = new Json.Parser();
            try {
                parser.load_from_data(stdout_data);
            } catch (Error e) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "%s produced invalid JSON: %s".printf(INVENTORY_HELPER, e.message));
            }
            var root_node = parser.get_root();
            if (root_node == null || root_node.get_node_type() != Json.NodeType.ARRAY) {
                throw new ArtistPackError.INVALID_RESPONSE("%s did not return a JSON array".printf(INVENTORY_HELPER));
            }

            var array = root_node.get_array();
            for (uint i = 0; i < array.get_length(); i++) {
                var obj = array.get_object_element(i);
                if (obj == null || !obj.has_member("package")) continue;
                results.add(new ArtistPackInfo(
                    obj.get_string_member("package"),
                    obj.has_member("title") ? obj.get_string_member("title") : obj.get_string_member("package"),
                    obj.has_member("summary") ? obj.get_string_member("summary") : "",
                    obj.has_member("version") ? obj.get_string_member("version") : "",
                    obj.has_member("source") ? obj.get_string_member("source") : "",
                    obj.has_member("installed") && obj.get_boolean_member("installed")
                ));
            }
            return results;
        }

        // `source` must be the value fetch_inventory_async() reported; the
        // privileged helper re-validates it and does not trust this argv.
        public async void install_async(string package, string source, Cancellable? cancellable = null) throws Error {
            if (!Regex.match_simple("^[a-z0-9][a-z0-9.+-]*$", package)) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: not a valid package name".printf(package));
            }
            if (source.strip().length == 0) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: no source URI given".printf(package));
            }
            if (!is_executable_file(INSTALL_HELPER)) {
                throw new ArtistPackError.BACKEND_MISSING("%s is not installed".printf(INSTALL_HELPER));
            }
            string? pkexec = find_pkexec();
            if (pkexec == null) {
                throw new ArtistPackError.BACKEND_MISSING("pkexec is not available");
            }

            var proc = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                                       pkexec, INSTALL_HELPER, package, source);
            string stdout_data;
            string stderr_data;
            yield proc.communicate_utf8_async(null, cancellable, out stdout_data, out stderr_data);
            if (!proc.get_successful()) {
                throw new ArtistPackError.BACKEND_FAILED(
                    "install of %s failed: %s".printf(package, (stderr_data ?? "").strip()));
            }
        }
    }
}
