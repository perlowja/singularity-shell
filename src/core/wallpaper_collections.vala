using GLib;
using Gee;

namespace Singularity {

    public class WallpaperCollectionInfo : Object {
        // Vala rejects a GObject property named "type"; keep these as fields.
        public string id;
        public string name;
        public string artist;
        public string dir;
        public string type;

        public WallpaperCollectionInfo(string id, string name, string artist, string dir, string type) {
            this.id = id;
            this.name = name;
            this.artist = artist;
            this.dir = dir;
            this.type = type;
        }
    }

    public class WallpaperCollections : Object {
        // parse() is first-root-wins, so system collections take precedence.
        public static string[] default_search_roots() {
            string[] roots = {};
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                roots += GLib.Path.build_filename(d, "singularity", "wallpaper-collections");
            roots += GLib.Path.build_filename(
                GLib.Environment.get_user_data_dir(), "singularity", "wallpaper-collections");
            return roots;
        }

        public static Gee.ArrayList<WallpaperCollectionInfo> parse(string[] search_roots) {
            var results = new Gee.ArrayList<WallpaperCollectionInfo>();
            var seen_ids = new Gee.HashSet<string>();

            foreach (string root in search_roots) {
                try {
                    var dir = File.new_for_path(root);
                    if (!dir.query_exists()) continue;
                    var en = dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE, null);
                    FileInfo info;
                    while ((info = en.next_file(null)) != null) {
                        string filename = info.get_name();
                        if (!filename.has_suffix(".collection")) continue;

                        var kf = new GLib.KeyFile();
                        try {
                            kf.load_from_file(GLib.Path.build_filename(root, filename), GLib.KeyFileFlags.NONE);
                        } catch (Error e) {
                            continue; // malformed file, skip it
                        }

                        string collection_dir;
                        try {
                            collection_dir = kf.get_string("Collection", "Dir").strip();
                        } catch (Error e) {
                            continue; // Dir-less collection, skip it
                        }
                        if (collection_dir == "") continue;

                        string id;
                        try {
                            id = kf.get_string("Collection", "Id").strip();
                        } catch (Error e) {
                            id = "";
                        }
                        if (id == "") {
                            id = filename.substring(0, filename.length - ".collection".length);
                        }
                        if (!seen_ids.add(id)) continue; // first root wins

                        string name;
                        try { name = kf.get_string("Collection", "Name").strip(); }
                        catch (Error e) { name = ""; }
                        if (name == "") name = id;

                        string artist;
                        try { artist = kf.get_string("Collection", "Artist").strip(); }
                        catch (Error e) { artist = ""; }

                        string type;
                        try { type = kf.get_string("Collection", "Type").strip(); }
                        catch (Error e) { type = ""; }
                        if (type == "") type = "static";

                        results.add(new WallpaperCollectionInfo(id, name, artist, collection_dir, type));
                    }
                } catch (Error e) {
                    continue;
                }
            }
            return results;
        }
    }
}
