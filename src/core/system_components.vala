namespace Singularity {

    /**
     * Versions, licenses and runtime capability checks for the components the
     * Singularity session depends on. Shown in the About page (credits + legal +
     * debug) and copied into bug reports.
     *
     * Versions resolve without dev tools (target hosts have no pkg-config):
     * GObject libraries the shell links report via their in-process API, tools
     * and the compositor via `--version`, other shared libraries by finding the
     * `.so` in the standard library directories.
     *
     * Critical components we require to be built/configured with specific
     * support (labwc, wlroots, Vulkan, Xwayland) also carry capability checks:
     * actual runtime tests (DRM device present, GPU render node, Vulkan ICDs,
     * X11 socket, labwc build features). A failed required capability raises a
     * warning on that component.
     */
    public class SystemComponents : Object {

        public struct Capability {
            public string label;
            public bool ok;
            public bool required;
        }

        public struct Component {
            public string name;
            public string version;
            public string license;
            public Capability[] caps;
            public bool warn;
        }

        // name, SPDX license, version probe.
        // probe: "gtk"|"glib"|"pango"|"cairo"|"json" | "wlroots" |
        //        "bin:<argv...>" | "lib:<soname-prefix>" | "fn:<soname>:<prefix>" | "var:<soname>:<symbol>"
        private const string[,] LIST = {
            { "labwc",              "GPL-2.0-only",        "bin:labwc --version" },
            { "wlroots",            "MIT",                 "wlroots" },
            { "Wayland",            "MIT",                 "lib:libwayland-server.so" },
            { "Xwayland",           "MIT",                 "bin:Xwayland -version" },
            { "Vulkan loader",      "Apache-2.0",          "lib:libvulkan.so" },
            { "libinput",           "MIT",                 "lib:libinput.so" },
            { "libxkbcommon",       "MIT",                 "lib:libxkbcommon.so" },
            { "pixman",             "MIT",                 "lib:libpixman-1.so" },
            { "gtk4-layer-shell",   "MIT",                 "lib:libgtk4-layer-shell.so" },
            { "libdecor",           "MIT",                 "lib:libdecor-0.so" },
            { "libliftoff",         "MIT",                 "lib:libliftoff.so" },
            { "GTK",                "LGPL-2.1-or-later",   "gtk" },
            { "GLib",               "LGPL-2.1-or-later",   "glib" },
            { "Pango",              "LGPL-2.1-or-later",   "pango" },
            { "Cairo",              "LGPL-2.1-or-later",   "cairo" },
            { "gdk-pixbuf",         "LGPL-2.1-or-later",   "var:libgdk_pixbuf-2.0.so.0:gdk_pixbuf_version" },
            { "VTE",                "LGPL-3.0-or-later",   "fn:libvte-2.91-gtk4.so.0:vte_get_" },
            { "GtkSourceView",      "LGPL-2.1-or-later",   "fn:libgtksourceview-5.so.0:gtk_source_get_" },
            { "libpeas",            "LGPL-2.1-or-later",   "lib:libpeas-2.so" },
            { "json-glib",          "LGPL-2.1-or-later",   "json" },
            { "libgee",             "LGPL-2.1-or-later",   "lib:libgee-0.8.so" },
            { "libsoup",            "LGPL-2.0-or-later",   "fn:libsoup-3.0.so.0:soup_get_" },
            { "D-Bus",              "AFL-2.1 OR GPL-2.0+", "bin:dbus-daemon --version" },
            { "PipeWire",           "MIT",                 "bin:pipewire --version" },
            { "WirePlumber",        "MIT",                 "bin:wireplumber --version" },
            { "xdg-desktop-portal", "LGPL-2.1-or-later",   "bin:/usr/libexec/xdg-desktop-portal --version" },
            { "polkit",             "LGPL-2.0-or-later",   "bin:pkaction --version" },
            { "NetworkManager",     "GPL-2.0-or-later",    "bin:NetworkManager --version" },
            { "BlueZ",              "GPL-2.0-or-later",    "bin:bluetoothctl --version" },
        };

        public static Component[] collect() {
            var list = new GenericArray<Component?>();
            string labwc_raw = run({ "labwc", "--version" }) ?? "";
            for (int i = 0; i < LIST.length[0]; i++) {
                string name = LIST[i, 0];
                var caps = caps_for(name, labwc_raw);
                bool warn = false;
                foreach (var c in caps) if (c.required && !c.ok) warn = true;
                string version = resolve(LIST[i, 2], labwc_raw);
                if (LIST[i, 2] == "gtk" && has_sit()) {
                    name = "SIT";
                    version = "GTK " + version;
                }
                list.add(Component() {
                    name = name,
                    license = LIST[i, 1],
                    version = version,
                    caps = caps,
                    warn = warn
                });
            }
            // The Wayland protocols the session requires. Tested live against the
            // running compositor's advertised registry globals: this is the only
            // component that proves the compositor actually is ours.
            string globals = wayland_list_globals();
            var pcaps = protocol_caps(globals);
            int active = 0;
            bool pwarn = false;
            foreach (var c in pcaps) {
                if (c.ok) active++;
                if (c.required && !c.ok) pwarn = true;
            }
            list.add(Component() {
                name = "Wayland protocols",
                license = "MIT OR Singularity",
                version = "%d / %d active".printf(active, pcaps.length),
                caps = pcaps,
                warn = pwarn
            });

            Component[] result = new Component[list.length];
            for (int i = 0; i < list.length; i++) result[i] = list[i];
            return result;
        }

        // Mandatory and optional Wayland protocols, each tested against the
        // compositor's advertised registry globals.
        private static Capability[] protocol_caps(string globals) {
            var c = new GenericArray<Capability?>();
            add_proto(c, globals, "Panel and dock surfaces (layer-shell)", "zwlr_layer_shell_v1", true);
            add_proto(c, globals, "Taskbar and dock (foreign-toplevel management)", "zwlr_foreign_toplevel_manager_v1", true);
            add_proto(c, globals, "Workspaces", "ext_workspace_manager_v1", true);
            add_proto(c, globals, "Window previews", "zsingularity_preview_manager_v1", true);
            add_proto(c, globals, "Tiling and snapping", "zsingularity_tiling_manager_v1", true);
            add_proto(c, globals, "Display configuration", "zwlr_output_manager_v1", true);
            add_proto(c, globals, "Lock screen", "ext_session_lock_manager_v1", true);
            add_proto(c, globals, "Screenshots", "zwlr_screencopy_manager_v1", true);
            add_proto(c, globals, "Screen casting", "ext_image_copy_capture_manager_v1", true);
            add_proto(c, globals, "Background blur", "zsingularity_blur_manager_v1", false);
            add_proto(c, globals, "Night light (gamma control)", "zwlr_gamma_control_manager_v1", false);
            Capability[] result = new Capability[c.length];
            for (int i = 0; i < c.length; i++) result[i] = c[i];
            return result;
        }

        private static void add_proto(GenericArray<Capability?> c, string globals, string label, string iface, bool required) {
            bool ok = ("\n" + globals).contains("\n" + iface + "\n");
            c.add(Capability() { label = label, ok = ok, required = required });
        }

        // Capability tests for the components we require to be built/configured
        // with specific support. Everything else returns no caps (a plain row).
        private static Capability[] caps_for(string name, string labwc_raw) {
            var c = new GenericArray<Capability?>();
            switch (name) {
                case "labwc":
                    c.add(Capability() { label = "XWayland support", ok = labwc_has_feature(labwc_raw, "xwayland"), required = true });
                    c.add(Capability() { label = "SVG icon rendering (rsvg)", ok = labwc_has_feature(labwc_raw, "rsvg"), required = false });
                    c.add(Capability() { label = "Translations (nls)", ok = labwc_has_feature(labwc_raw, "nls"), required = false });
                    c.add(Capability() { label = "Desktop/icon lookup (libsfdo)", ok = labwc_has_feature(labwc_raw, "libsfdo"), required = false });
                    break;
                case "wlroots":
                    c.add(Capability() { label = "DRM / KMS device", ok = has_drm_card(), required = true });
                    c.add(Capability() { label = "GPU render node", ok = has_render_node(), required = true });
                    break;
                case "Vulkan loader":
                    c.add(Capability() { label = "Vulkan ICD installed", ok = vulkan_icd_count() > 0, required = true });
                    c.add(Capability() { label = "GPU render node", ok = has_render_node(), required = true });
                    break;
                case "Xwayland":
                    c.add(Capability() { label = "X11 display socket", ok = has_x_socket(), required = false });
                    break;
            }
            Capability[] result = new Capability[c.length];
            for (int i = 0; i < c.length; i++) result[i] = c[i];
            return result;
        }

        // --- capability tests ---

        private static bool dir_has_prefix(string dir, string prefix) {
            try {
                var d = Dir.open(dir);
                string? n;
                while ((n = d.read_name()) != null) if (n.has_prefix(prefix)) return true;
            } catch (FileError e) {}
            return false;
        }

        private static bool has_drm_card() { return dir_has_prefix("/dev/dri", "card"); }
        private static bool has_render_node() { return dir_has_prefix("/dev/dri", "renderD"); }
        private static bool has_x_socket() {
            if (dir_has_prefix("/tmp/.X11-unix", "X")) return true;
            return Environment.get_variable("DISPLAY") != null;
        }

        private static int vulkan_icd_count() {
            int n = 0;
            foreach (string dir in new string[] { "/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d" }) {
                try {
                    var d = Dir.open(dir);
                    string? name;
                    while ((name = d.read_name()) != null) if (name.has_suffix(".json")) n++;
                } catch (FileError e) {}
            }
            return n;
        }

        private static bool labwc_has_feature(string raw, string feature) {
            return raw.contains("+" + feature);
        }

        // --- version resolution ---

        private static string resolve(string probe, string labwc_raw) {
            if (probe == "gtk")
                return "%u.%u.%u".printf(Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version());
            if (probe == "glib")
                return "%u.%u.%u".printf(GLib.Version.major, GLib.Version.minor, GLib.Version.micro);
            if (probe == "pango") return Pango.version_string();
            if (probe == "cairo") return Cairo.version_string();
            if (probe == "json")
                return "%d.%d.%d".printf(Json.MAJOR_VERSION, Json.MINOR_VERSION, Json.MICRO_VERSION);
            if (probe == "wlroots") {
                if (labwc_raw == "") return "Not installed";
                try {
                    var re = new Regex("wlroots[- ]([0-9][0-9A-Za-z._-]*)");
                    MatchInfo mi;
                    if (re.match(labwc_raw, 0, out mi)) return mi.fetch(1);
                } catch (RegexError e) {}
                return "unknown";
            }
            if (probe.has_prefix("bin:")) {
                string? raw = run(probe.substring(4).split(" "));
                return (raw != null) ? extract_version(raw) : "Not installed";
            }
            if (probe.has_prefix("lib:")) return lib_version(probe.substring(4));
            if (probe.has_prefix("fn:")) return fn_version(probe.substring(3));
            if (probe.has_prefix("var:")) return var_version(probe.substring(4));
            return "Not installed";
        }

        [CCode (has_target = false)]
        private delegate uint VersionPart();

        private static string fn_version(string spec) {
            string[] parts = spec.split(":", 2);
            var module = Module.open(parts[0], ModuleFlags.LAZY | ModuleFlags.LOCAL);
            if (module == null) return "Not installed";
            string[] names = { "major_version", "minor_version", "micro_version" };
            uint[] values = {};
            foreach (string n in names) {
                void* sym;
                if (!module.symbol(parts[1] + n, out sym) || sym == null) return "Installed";
                VersionPart part = (VersionPart) sym;
                values += part();
            }
            return "%u.%u.%u".printf(values[0], values[1], values[2]);
        }

        private static string var_version(string spec) {
            string[] parts = spec.split(":", 2);
            var module = Module.open(parts[0], ModuleFlags.LAZY | ModuleFlags.LOCAL);
            if (module == null) return "Not installed";
            void* sym;
            if (!module.symbol(parts[1], out sym) || sym == null) return "Installed";
            char** p = (char**) sym;
            if (*p == null) return "Installed";
            unowned string v = (string) (*p);
            return v != "" ? v : "Installed";
        }

        private static bool has_sit() {
            var self = Module.open(null, 0);
            void* sym = null;
            return self != null && self.symbol("sit_widget_set_visual_transform", out sym) && sym != null;
        }

        private static string? run(string[] argv) {
            try {
                string out_s, err_s;
                int status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH,
                    null, out out_s, out err_s, out status);
                string combined = (out_s ?? "") + (err_s ?? "");
                return (combined.strip() == "") ? null : combined;
            } catch (SpawnError e) {
                return null;
            }
        }

        private static string lib_version(string prefix) {
            string[] dirs = {
                "/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib",
                "/lib/x86_64-linux-gnu", "/opt/local/lib"
            };
            foreach (string d in dirs) {
                string best = "";
                try {
                    var dir = Dir.open(d);
                    string? n;
                    while ((n = dir.read_name()) != null)
                        if (n.has_prefix(prefix) && n.length > best.length) best = n;
                } catch (FileError e) { continue; }
                if (best == "") continue;
                return "Installed";
            }
            return "Not installed";
        }

        private static string extract_version(string blob) {
            try {
                var re = new Regex("[0-9]+\\.[0-9]+(\\.[0-9]+)?([0-9A-Za-z._-]*)?");
                MatchInfo mi;
                if (re.match(blob, 0, out mi)) {
                    string m = mi.fetch(0);
                    if (m != null && m != "") return m;
                }
            } catch (RegexError e) {}
            foreach (string line in blob.split("\n")) {
                string t = line.strip();
                if (t != "") return t;
            }
            return "unknown";
        }

        public static string to_markdown(Component[] comps) {
            var sb = new StringBuilder();
            sb.append("## Singularity system components\n\n");
            sb.append("| Component | Version | License |\n");
            sb.append("|-----------|---------|---------|\n");
            foreach (var c in comps)
                sb.append_printf("| %s%s | %s | %s |\n", c.warn ? "⚠ " : "", c.name, c.version, c.license);
            bool any = false;
            foreach (var c in comps) if (c.caps.length > 0) { any = true; break; }
            if (any) {
                sb.append("\n### Capabilities\n\n");
                foreach (var c in comps) {
                    if (c.caps.length == 0) continue;
                    sb.append_printf("- **%s**\n", c.name);
                    foreach (var cap in c.caps)
                        sb.append_printf("  - %s %s%s\n", cap.ok ? "✅" : "❌",
                            cap.label, (!cap.ok && cap.required) ? " (required)" : "");
                }
            }
            return sb.str;
        }
    }
}
