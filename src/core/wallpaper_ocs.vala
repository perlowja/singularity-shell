using GLib;
using Gee;

namespace Singularity {
    public errordomain WallpaperOcsError { INVALID }
    public class WallpaperOcsChoice : Object {
        public string id;
        public string name;
        public WallpaperOcsChoice(string id, string name) { this.id = id; this.name = name; }
    }
    public class WallpaperOcsItem : Object {
        public string provider = "";
        public string id = "";
        public string name = "";
        public string author = "";
        public string license = "";
        public string preview = "";
        // Tags emitted per item by the OCS browse response (JSON array of
        // plain strings, possibly empty). Parsed leniently: absent field or
        // explicit empty array both become an empty list, matching how the
        // other optional string fields default to "". A value that is not
        // an array of strings is a parse error, consistent with the other
        // shape checks in this class.
        public string[] tags = {};
        public string key { owned get { return provider + ":" + id; } }
    }
    // JSON from the helper is untrusted. Check types before Json-GLib getters,
    // which otherwise emit criticals (fatal in the GLib.Test harness).
    public class WallpaperOcs : Object {
        internal static Json.Object object_node(Json.Node? node) throws Error {
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT)
                throw new WallpaperOcsError.INVALID("Expected a JSON object");
            return node.get_object();
        }
        internal static Json.Object document(string data, bool schema = true) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            var obj = object_node(parser.get_root());
            if (schema) {
                var node = obj.get_member("schema");
                if (node == null || node.get_value_type() != typeof(int64) || node.get_int() != 1)
                    throw new WallpaperOcsError.INVALID("Unsupported OCS response schema");
            }
            return obj;
        }
        internal static string text(Json.Object obj, string field, bool required = true) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) {
                if (!required) return "";
                throw new WallpaperOcsError.INVALID("Missing OCS field: " + field);
            }
            if (node.get_value_type() != typeof(string))
                throw new WallpaperOcsError.INVALID("Invalid OCS field: " + field);
            string value = node.get_string();
            if (required && value.strip() == "")
                throw new WallpaperOcsError.INVALID("Empty OCS field: " + field);
            return value;
        }
        internal static Json.Array array(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Invalid OCS list: " + field);
            return node.get_array();
        }
        // Tags are emitted as a JSON array of strings. Absent field or empty
        // array both collapse to an empty list; anything else (non-array, or
        // any non-string element) is rejected so a malformed response cannot
        // silently degrade the filter UI.
        internal static string[] tag_array(Json.Object obj, string field) throws Error {
            var node = obj.get_member(field);
            if (node == null || node.is_null()) return {};
            if (node.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Invalid OCS list: " + field);
            var arr = node.get_array();
            var result = new Gee.ArrayList<string>();
            foreach (var element in arr.get_elements()) {
                if (element == null || element.get_value_type() != typeof(string))
                    throw new WallpaperOcsError.INVALID("Invalid OCS tag entry: " + field);
                string t = element.get_string().strip();
                if (t != "" && !result.contains(t)) result.add(t);
            }
            return result.to_array();
        }
        internal static bool numeric_id(string id) {
            if (id.length == 0) return false;
            foreach (char c in id.to_utf8()) if (c < '0' || c > '9') return false;
            return true;
        }
        internal static bool provider_id(string id) {
            return id == "pling" || id == "opendesktop" || id == "kde-look" || id == "gnome-look";
        }
        public static ArrayList<WallpaperOcsChoice> providers(string data) throws Error {
            var obj = object_node(document(data).get_member("providers"));
            var result = new ArrayList<WallpaperOcsChoice>();
            foreach (string id in obj.get_members()) {
                if (!provider_id(id)) throw new WallpaperOcsError.INVALID("Unknown OCS provider: " + id);
                text(object_node(obj.get_member(id)), "base");
                result.add(new WallpaperOcsChoice(id, id));
            }
            result.sort((a, b) => strcmp(a.id, b.id));
            return result;
        }
        public static ArrayList<WallpaperOcsChoice> categories(string data, string provider) throws Error {
            var entries = array(document(data), "entries");
            var seen = new HashSet<string>();
            var result = new ArrayList<WallpaperOcsChoice>();
            foreach (var node in entries.get_elements()) {
                var entry = object_node(node);
                string reference = text(entry, "ref");
                if (!reference.has_prefix(provider + ":")) continue;
                string id = reference.substring(provider.length + 1);
                if (!numeric_id(id)) throw new WallpaperOcsError.INVALID("Invalid OCS category identity");
                var usable = entry.get_member("usable");
                if (usable == null || usable.get_value_type() != typeof(bool))
                    throw new WallpaperOcsError.INVALID("Invalid OCS category usability");
                if (!usable.get_boolean() || !seen.add(id)) continue;
                string name = text(entry, "display_name", false);
                if (name == "") name = text(entry, "name");
                result.add(new WallpaperOcsChoice(id, name));
            }
            result.sort((a, b) => a.name.collate(b.name));
            return result;
        }
        public static ArrayList<WallpaperOcsItem> items(string data, string provider, string category) throws Error {
            var obj = document(data);
            if (text(obj, "provider") != provider || text(obj, "category") != category)
                throw new WallpaperOcsError.INVALID("OCS response does not match the requested category");
            var result = new ArrayList<WallpaperOcsItem>();
            var seen = new HashSet<string>();
            foreach (var node in array(obj, "items").get_elements()) {
                var entry = object_node(node);
                var item = new WallpaperOcsItem();
                item.provider = text(entry, "provider");
                item.id = text(entry, "id");
                if (item.provider != provider || !provider_id(provider) || !numeric_id(item.id))
                    throw new WallpaperOcsError.INVALID("Invalid OCS item identity");
                item.name = text(entry, "name");
                item.author = text(entry, "author", false);
                item.license = text(entry, "license", false);
                item.preview = text(entry, "preview", false);
                item.tags = tag_array(entry, "tags");
                if (seen.add(item.key)) result.add(item);
            }
            return result;
        }
    }
    // The backend owns disk writes. This model tracks an active import and
    // reconciles completed imports against its real registry/provenance files.
    //
    // OCS imports accumulate into ONE shared user-side collection ("Imported
    // from OCS", Id=imported-ocs). Per-image provenance is in per-image
    // sidecar JSON files (<image>.json) sitting next to each <image>.jpg in
    // the collection's Dir. discover() scans sidecars to know what is already
    // imported; complete() validates that each per-image response actually
    // landed on disk and that the sidecar's (provider, ocs_id) matches the
    // key the browser tried to import -- never mark "added" without real
    // files landing under the right identity.
    public class WallpaperOcsImports : Object {
        private string active = "";
        private HashSet<string> added = new HashSet<string>();
        public bool busy { get { return active != ""; } }
        public bool begin(string key) {
            if (busy || added.contains(key)) return false;
            active = key;
            return true;
        }
        public void fail(string key) { if (active == key) active = ""; }
        public bool is_added(string key) { return added.contains(key); }
        // Scan the sidecar files in `dir` (one per imported image) and return
        // every "provider:id" pair represented by a well-formed sidecar whose
        // image file also exists on disk. Old-shape directories from earlier
        // one-pack-per-import testing have no sidecars and silently contribute
        // nothing, which is what discover() wants.
        private static Gee.ArrayList<string> sidecar_keys(string dir) {
            var result = new Gee.ArrayList<string>();
            if (!FileUtils.test(dir, FileTest.IS_DIR)) return result;
            string data;
            var listing = Dir.open(dir);
            string? name;
            while ((name = listing.read_name()) != null) {
                if (!name.has_suffix(".json")) continue;
                string sidecar_path = Path.build_filename(dir, name);
                if (!FileUtils.test(sidecar_path, FileTest.IS_REGULAR)) continue;
                string image_basename = name.substring(0, name.length - ".json".length);
                if (!FileUtils.test(Path.build_filename(dir, image_basename + ".jpg"), FileTest.IS_REGULAR))
                    continue;
                try {
                    FileUtils.get_contents(sidecar_path, out data);
                    var doc = WallpaperOcs.document(data, false);
                    if (WallpaperOcs.text(doc, "origin") != "ocs") continue;
                    string provider = WallpaperOcs.text(doc, "provider");
                    string id = WallpaperOcs.text(WallpaperOcs.object_node(doc.get_member("source")), "ocs_id");
                    if (!WallpaperOcs.provider_id(provider) || !WallpaperOcs.numeric_id(id)) continue;
                    result.add(provider + ":" + id);
                } catch (Error e) {
                    /* malformed sidecar is not an import */
                }
            }
            return result;
        }
        public void discover(ArrayList<WallpaperCollectionInfo> collections) {
            added.clear();
            foreach (var collection in collections) {
                foreach (string key in sidecar_keys(collection.dir)) added.add(key);
            }
        }
        // The single shared "Imported from OCS" collection: registered once on
        // first import, identity never changes across imports. The picker
        // surfaces it the same way as any other pack because the .collection
        // file lives in the user search roots.
        private const string IMPORTED_OCS_ID = "imported-ocs";
        public void complete(string key, string data, string[] roots) throws Error {
            if (active != key) throw new WallpaperOcsError.INVALID("No matching import is active");
            var obj = WallpaperOcs.document(data, false);
            string id = WallpaperOcs.text(obj, "pack_id");
            string dir = WallpaperOcs.text(obj, "destination");
            string collection_path = WallpaperOcs.text(obj, "collection");
            if (id != IMPORTED_OCS_ID)
                throw new WallpaperOcsError.INVALID("Import does not target the shared imported-ocs collection");
            if (!Path.is_absolute(dir) || !FileUtils.test(dir, FileTest.IS_DIR) ||
                !FileUtils.test(collection_path, FileTest.IS_REGULAR))
                throw new WallpaperOcsError.INVALID("Import did not produce registered collection files");
            bool registered = false;
            foreach (var collection in WallpaperCollections.parse(roots)) {
                if (collection.id == id && collection.dir == dir) { registered = true; break; }
            }
            if (!registered)
                throw new WallpaperOcsError.INVALID("Imported pack is missing from the collection registry");
            // Per-image files: every image in the response must point to a real
            // sidecar file with a real .jpg next to it, AND the sidecar's
            // provider:ocs_id must match the import's key. This preserves the
            // old class's safety property: never mark something added unless
            // real files actually landed on disk under the right identity.
            var images = WallpaperOcs.array(obj, "images");
            if (images.get_length() == 0)
                throw new WallpaperOcsError.INVALID("Imported pack contains no images");
            bool found_key = false;
            foreach (var node in images.get_elements()) {
                var image = WallpaperOcs.object_node(node);
                // `file` and `sidecar` are basenames in the response payload,
                // mirroring the old per-pack `file` field shape; the absolute
                // path is built against the shared collection's `dir`.
                string name = WallpaperOcs.text(image, "file");
                string sidecar = WallpaperOcs.text(image, "sidecar");
                if (name != Path.get_basename(name) || !name.has_suffix(".jpg") ||
                    !FileUtils.test(Path.build_filename(dir, name), FileTest.IS_REGULAR))
                    throw new WallpaperOcsError.INVALID("Imported image is missing");
                if (sidecar != Path.get_basename(sidecar) || !sidecar.has_suffix(".json"))
                    throw new WallpaperOcsError.INVALID("Imported image sidecar path is malformed");
                if (sidecar != name.substring(0, name.length - ".jpg".length) + ".json")
                    throw new WallpaperOcsError.INVALID("Imported image sidecar does not pair with image");
                string sidecar_path = Path.build_filename(dir, sidecar);
                if (!FileUtils.test(sidecar_path, FileTest.IS_REGULAR))
                    throw new WallpaperOcsError.INVALID("Imported image sidecar is missing");
                string sidecar_data;
                FileUtils.get_contents(sidecar_path, out sidecar_data);
                var sidecar_doc = WallpaperOcs.document(sidecar_data, false);
                string provider = WallpaperOcs.text(sidecar_doc, "provider");
                string ocs_id = WallpaperOcs.text(WallpaperOcs.object_node(sidecar_doc.get_member("source")), "ocs_id");
                string candidate = provider + ":" + ocs_id;
                if (candidate == key) found_key = true;
            }
            if (!found_key)
                throw new WallpaperOcsError.INVALID("No imported image sidecar matches the active import key");
            added.add(key);
            active = "";
        }
    }
}
