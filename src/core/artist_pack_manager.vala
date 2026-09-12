using GLib;
using Gee;
using Json;

namespace Singularity {

    /**
     * One curated Artist Pack, available or already installed, from one of
     * the apt sources configured in dev.sinty.desktop's
     * artist-pack-apt-sources.
     */
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

    /**
     * Browses and installs curated Artist Packs (ncz-wallpapers-* debs).
     *
     * This class deliberately knows nothing about apt. It shells out to two
     * distro-provided scripts, `ncz-wallpaper-pack-inventory` and
     * `ncz-wallpaper-pack-install`, resolved by name via PATH - the same
     * pattern ScriptSearchProvider uses for search providers. A distro that
     * does not ship them (including a non-NCZ / upstream build of this
     * desktop) simply has is_available() return false, and the Artist Pack
     * browser hides itself entirely: this is additive, opt-in integration,
     * not something the shell hard-depends on.
     *
     * Which apt source(s) count as "an artist pack source" is entirely the
     * distro's call, read by the inventory script from the
     * dev.sinty.desktop `artist-pack-apt-sources` GSettings key - this class
     * never reads or filters on that value itself, so the browser and the
     * source policy stay independently configurable.
     *
     * install_async() intentionally takes the exact `source` URI the
     * inventory script already reported for a pack, and passes it through
     * to the privileged install helper as its own argv (rather than the
     * privileged helper re-deriving "which sources are trusted" itself by
     * re-reading GSettings as root under pkexec). The helper still
     * independently re-checks that argv-supplied source both against the
     * apt sources actually configured on the system and against the
     * package's live apt candidate before installing anything - it does not
     * blindly trust the caller. This split matters because GSettings/dconf
     * is a per-user mechanism: a `pkexec`-elevated root process does not
     * share the desktop user's dconf session, so having the privileged side
     * re-read a GSettings key is fragile in a way that reading a plain,
     * root-owned apt sources file is not. See the install helper and
     * packaging/singularity/README.md for the full reasoning.
     */
    public class ArtistPackManager : GLib.Object {
        private static ArtistPackManager? _instance = null;
        private const string INVENTORY_HELPER = "ncz-wallpaper-pack-inventory";
        private const string INSTALL_HELPER = "ncz-wallpaper-pack-install";

        public static ArtistPackManager get_default() {
            if (_instance == null) _instance = new ArtistPackManager();
            return _instance;
        }

        private ArtistPackManager() { }

        /** True when the distro provides the inventory backend. */
        public bool is_available() {
            return Environment.find_program_in_path(INVENTORY_HELPER) != null;
        }

        /**
         * Queries the configured apt source(s) for available Artist Packs.
         *
         * Returns an empty list (not an error) when the backend is absent,
         * so a caller that already checked is_available() doesn't need a
         * second error path. A real backend failure (non-zero exit, bad
         * JSON) still throws.
         */
        public async Gee.ArrayList<ArtistPackInfo> fetch_inventory_async(Cancellable? cancellable = null) throws Error {
            var results = new Gee.ArrayList<ArtistPackInfo>();
            string? helper = Environment.find_program_in_path(INVENTORY_HELPER);
            if (helper == null) return results;

            var proc = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE, helper);
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

        /**
         * Installs one Artist Pack via pkexec + the distro's install helper.
         *
         * `source` must be the exact `source` URI the inventory step
         * already reported for this package (ArtistPackInfo.source) - it is
         * passed through to the privileged helper as argv, which
         * re-validates it independently rather than trusting this call.
         * Never pass anything here other than a value that came back from
         * fetch_inventory_async().
         *
         * Idempotent by construction: the helper's own `apt-get install` is
         * a no-op (exit 0) when the package is already at the candidate
         * version, so calling this on an already-installed pack is a safe,
         * repeatable no-op rather than an error. The package-name shape
         * check here is defense in depth only - the privileged helper
         * re-validates both the name and the source against the system's
         * actual apt configuration and the package's live apt candidate
         * before touching apt, so this check existing or not does not
         * change what the helper will actually do.
         */
        public async void install_async(string package, string source, Cancellable? cancellable = null) throws Error {
            if (!Regex.match_simple("^ncz-wallpapers-[a-z0-9][a-z0-9-]*$", package)) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: not an Artist Pack package name".printf(package));
            }
            if (source.strip().length == 0) {
                throw new ArtistPackError.INVALID_RESPONSE(
                    "Refusing to install %s: no source URI given".printf(package));
            }
            string? helper = Environment.find_program_in_path(INSTALL_HELPER);
            if (helper == null) {
                throw new ArtistPackError.BACKEND_MISSING("%s is not installed".printf(INSTALL_HELPER));
            }
            string? pkexec = Environment.find_program_in_path("pkexec");
            if (pkexec == null) {
                throw new ArtistPackError.BACKEND_MISSING("pkexec is not available");
            }

            var proc = new Subprocess(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE,
                                       pkexec, helper, package, source);
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
