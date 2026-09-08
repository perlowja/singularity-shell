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
        public string attribution = "";
        public string page_url = "";
        public string license_url = "";
        // Tags emitted per item by the OCS browse response (JSON array of
        // plain strings, possibly empty). Parsed leniently: absent field or
        // explicit empty array both become an empty list, matching how the
        // other optional string fields default to "". A value that is not
        // an array of strings is a parse error, consistent with the other
        // shape checks in this class.
        public string[] tags = {};
        // Bing-only fields. Defaults keep the existing OCS shape unchanged:
        // every OCS item has an empty thumbnail_path (the Soup thumbnail
        // path uses item.preview, a remote URL), is not pinned, and has no
        // market. The browser treats these as additive, not load-bearing
        // for OCS items.
        public string thumbnail_path = "";
        public bool pinned = false;
        public string market = "";
        public string archive_date = "";
        public string bing_image_id = "";
        // Canonical identity. For OCS this is "provider:numeric_id"; for Bing
        // it is "provider:market:Bing-image-id", falling back to archive date
        // for metadata written by older helpers. Keeping `key` stable
        // across both item kinds means add_card / filter_cards / the imports
        // map do not need a parallel data path.
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
                // opendesktop.org is the former name of pling.com. Both API
                // hosts currently expose the same catalog, so showing both
                // only duplicates every result. Keep accepting the legacy id
                // for existing provenance, but expose the current Pling
                // service once in the provider picker.
                if (id == "opendesktop") continue;
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
                string network = reference.split(":")[0];
                if (!reference.has_prefix(network + ":"))
                    throw new WallpaperOcsError.INVALID("Invalid OCS category reference");
                if (provider == "ocs" ? (!provider_id(network) || network == "opendesktop") : network != provider) continue;
                string id = reference.substring(network.length + 1);
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
                if ((provider != "ocs" && item.provider != provider) || !provider_id(item.provider) || !numeric_id(item.id))
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
    // Bing is not a JSON-over-OCS feed; it talks to a different helper
    // (ncz-wallpaper-bing) with its own command grammar. The browser treats
    // it as a fifth pseudo-provider in the provider row but its command and
    // response shapes are kept here, out of WallpaperOcs.providers(), so the
    // OCS parser remains strictly about OCS data. WallpaperBing shares
    // WallpaperOcsChoice so the category chip row can render markets the same
    // way it renders OCS categories, and shares WallpaperOcsItem so the rest
    // of the browser (add_card, filter_cards, thumbnails) keeps a single
    // code path. The Bing-only fields on WallpaperOcsItem (thumbnail_path,
    // pinned, market) default to empty/false for OCS items and are populated
    // by items() below.
    public class WallpaperBing : Object {
        // The synthetic provider id used by every Bing item and the browser's
        // SelectionRow. Hard-coded so the same string shows up in tests, the
        // browser, and any future call site that needs to recognise Bing.
        public const string PROVIDER_ID = "bing";
        // `ncz-wallpaper-bing markets` prints TSV, NOT JSON: one
        // "<market-code>\t<Human Name>" per line. The category chip row
        // expects an ArrayList<WallpaperOcsChoice> just like the OCS
        // categories() does, so we parse the TSV into the same shape.
        // Tolerates trailing whitespace, blank lines, and lines with no tab
        // (those are skipped, not treated as errors -- the helper's real
        // output is well-formed, but the parser is the safety belt).
        public static ArrayList<WallpaperOcsChoice> markets(string data) throws Error {
            var result = new ArrayList<WallpaperOcsChoice>();
            var seen = new HashSet<string>();
            foreach (var raw in data.split("\n")) {
                string line = raw.strip();
                if (line == "") continue;
                int tab = line.index_of("\t");
                if (tab < 0) continue;
                string id = line.substring(0, tab).strip();
                string name = line.substring(tab + 1).strip();
                if (id == "" || name == "") continue;
                if (!seen.add(id)) continue;
                result.add(new WallpaperOcsChoice(id, name));
            }
            result.sort((a, b) => a.name.collate(b.name));
            return result;
        }
        // `ncz-wallpaper-bing list <market>` returns a JSON ARRAY (no
        // schema/items wrapper, unlike the OCS helper). Each element carries:
        //   provider, date, market, path, caption, copyright,
        //   thumbnail_path, pinned
        // Parse the array into the shared WallpaperOcsItem shape. `id` on the
        // item is set to "<market>:<Bing image id>" so the existing key=
        // "provider:id" formula produces a unique, stable identity per Bing
        // archived image. Tags: Bing has no per-image tags; the field stays
        // empty so filter_cards does not need to special-case anything.
        public static ArrayList<WallpaperOcsItem> items(string data) throws Error {
            var parser = new Json.Parser();
            parser.load_from_data(data);
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY)
                throw new WallpaperOcsError.INVALID("Expected a Bing list array");
            var arr = root.get_array();
            var result = new ArrayList<WallpaperOcsItem>();
            var seen = new HashSet<string>();
            foreach (var node in arr.get_elements()) {
                if (node == null || node.get_node_type() != Json.NodeType.OBJECT)
                    throw new WallpaperOcsError.INVALID("Invalid Bing list entry");
                var entry = node.get_object();
                var item = new WallpaperOcsItem();
                item.provider = PROVIDER_ID;
                // Provider field is required and must equal "bing"; this
                // catches a helper that ever emits mixed provider types in
                // the same list.
                if (WallpaperOcs.text(entry, "provider") != PROVIDER_ID)
                    throw new WallpaperOcsError.INVALID("Bing list entry has unexpected provider");
                item.market = WallpaperOcs.text(entry, "market");
                item.archive_date = WallpaperOcs.text(entry, "date");
                item.bing_image_id = WallpaperOcs.text(entry, "image_id", false);
                item.name = WallpaperOcs.text(entry, "caption", false);
                // Composite id keeps item.key unique across markets; this id
                // is purely the identity for add_card / the imports map.
                item.id = item.market + ":" + (item.bing_image_id != "" ? item.bing_image_id : item.archive_date);
                item.author = WallpaperOcs.text(entry, "copyright", false);
                item.license = ""; // Bing does not emit a license field; honest default.
                item.preview = ""; // No remote preview URL for Bing -- the
                                   // thumbnail_path is loaded locally below.
                item.thumbnail_path = WallpaperOcs.text(entry, "thumbnail_path", false);
                var pin = entry.get_member("pinned");
                if (pin == null || pin.get_value_type() != typeof(bool))
                    throw new WallpaperOcsError.INVALID("Invalid Bing pinned field");
                item.pinned = pin.get_boolean();
                // Empty tags stays empty; do NOT synthesise a market-as-tag
                // here (operator-confirmed design decision: a market name
                // is not a wallpaper tag, it is a filter axis via the chip
                // row, which already uses categories).
                if (seen.add(item.key)) result.add(item);
            }
            return result;
        }
    }
    // Openverse is a photo search API, not an OCS network. Its helper emits
    // a normalized envelope while retaining per-image licensing and links.
    public class WallpaperOpenverse : Object {
        public static ArrayList<WallpaperOcsItem> items(string data) throws Error {
            var obj = WallpaperOcs.document(data);
            var result = new ArrayList<WallpaperOcsItem>();
            var seen = new HashSet<string>();
            foreach (var node in WallpaperOcs.array(obj, "items").get_elements()) {
                var entry = WallpaperOcs.object_node(node);
                var item = new WallpaperOcsItem();
                item.provider = WallpaperOcs.text(entry, "provider");
                item.id = WallpaperOcs.text(entry, "id");
                if (item.provider != "openverse" || !Uuid.string_is_valid(item.id))
                    throw new WallpaperOcsError.INVALID("Invalid Openverse identity");
                item.name = WallpaperOcs.text(entry, "name", false);
                item.author = WallpaperOcs.text(entry, "author", false);
                item.preview = WallpaperOcs.text(entry, "preview");
                item.license = WallpaperOcs.text(entry, "license") + " " + WallpaperOcs.text(entry, "license_version", false);
                item.attribution = WallpaperOcs.text(entry, "attribution", false);
                item.page_url = WallpaperOcs.text(entry, "page_url", false);
                item.license_url = WallpaperOcs.text(entry, "license_url", false);
                item.tags = WallpaperOcs.tag_array(entry, "tags");
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
                if (!FileUtils.test(Path.build_filename(dir, image_basename + ".jpg"), FileTest.IS_REGULAR) &&
                    !FileUtils.test(Path.build_filename(dir, image_basename + ".png"), FileTest.IS_REGULAR) &&
                    !FileUtils.test(Path.build_filename(dir, image_basename + ".webp"), FileTest.IS_REGULAR))
                    continue;
                try {
                    FileUtils.get_contents(sidecar_path, out data);
                    var doc = WallpaperOcs.document(data, false);
                    if (WallpaperOcs.text(doc, "provider", false) == "openverse") {
                        string identity = WallpaperOcs.text(doc, "id");
                        if (Uuid.string_is_valid(identity)) result.add("openverse:" + identity);
                        continue;
                    }
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
        // Older installed helpers create one directory per import and put the
        // provenance in pack.json instead of per-image sidecars. Accept that
        // deployed format while installations transition to the shared pack.
        private static string legacy_pack_key(string dir) {
            string path = Path.build_filename(dir, "pack.json");
            if (!FileUtils.test(path, FileTest.IS_REGULAR)) return "";
            try {
                string data;
                FileUtils.get_contents(path, out data);
                var doc = WallpaperOcs.document(data, false);
                if (WallpaperOcs.text(doc, "origin") != "ocs") return "";
                string provider = WallpaperOcs.text(doc, "provider");
                string id = WallpaperOcs.text(WallpaperOcs.object_node(doc.get_member("source")), "ocs_id");
                if (!WallpaperOcs.provider_id(provider) || !WallpaperOcs.numeric_id(id)) return "";
                foreach (var node in WallpaperOcs.array(doc, "images").get_elements()) {
                    string name = WallpaperOcs.text(WallpaperOcs.object_node(node), "file");
                    if (name == Path.get_basename(name) && name.has_suffix(".jpg") &&
                        FileUtils.test(Path.build_filename(dir, name), FileTest.IS_REGULAR))
                        return provider + ":" + id;
                }
            } catch (Error e) {
                /* malformed legacy metadata is not an import */
            }
            return "";
        }
        public void discover(ArrayList<WallpaperCollectionInfo> collections) {
            added.clear();
            foreach (var collection in collections) {
                foreach (string key in sidecar_keys(collection.dir)) added.add(key);
                string legacy = legacy_pack_key(collection.dir);
                if (legacy != "") added.add(legacy);
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
            if (!Path.is_absolute(dir) || !FileUtils.test(dir, FileTest.IS_DIR) ||
                !FileUtils.test(collection_path, FileTest.IS_REGULAR))
                throw new WallpaperOcsError.INVALID("Import did not produce registered collection files");
            bool registered = false;
            foreach (var collection in WallpaperCollections.parse(roots)) {
                if (collection.id == id && collection.dir == dir) { registered = true; break; }
            }
            if (!registered)
                throw new WallpaperOcsError.INVALID("Imported pack is missing from the collection registry");
            string provider_id = key.split(":")[0];
            if (id != IMPORTED_OCS_ID && id != "ocs" && id != provider_id) {
                string candidate = legacy_pack_key(dir);
                if (candidate != key)
                    throw new WallpaperOcsError.INVALID("Legacy imported pack provenance does not match the active import key");
                added.add(key);
                active = "";
                return;
            }
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
                if (name != Path.get_basename(name) ||
                    !(name.has_suffix(".jpg") || name.has_suffix(".png") || name.has_suffix(".webp")) ||
                    !FileUtils.test(Path.build_filename(dir, name), FileTest.IS_REGULAR))
                    throw new WallpaperOcsError.INVALID("Imported image is missing");
                if (sidecar != Path.get_basename(sidecar) || !sidecar.has_suffix(".json"))
                    throw new WallpaperOcsError.INVALID("Imported image sidecar path is malformed");
                if (sidecar != name.substring(0, name.last_index_of(".")) + ".json")
                    throw new WallpaperOcsError.INVALID("Imported image sidecar does not pair with image");
                string sidecar_path = Path.build_filename(dir, sidecar);
                if (!FileUtils.test(sidecar_path, FileTest.IS_REGULAR))
                    throw new WallpaperOcsError.INVALID("Imported image sidecar is missing");
                string sidecar_data;
                FileUtils.get_contents(sidecar_path, out sidecar_data);
                var sidecar_doc = WallpaperOcs.document(sidecar_data, false);
                string provider = WallpaperOcs.text(sidecar_doc, "provider");
                string ocs_id = provider == "openverse" ? WallpaperOcs.text(sidecar_doc, "id") :
                    WallpaperOcs.text(WallpaperOcs.object_node(sidecar_doc.get_member("source")), "ocs_id");
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
