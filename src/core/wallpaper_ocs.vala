using GLib;
using Gee;

namespace Singularity {
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
                    if (WallpaperOcs.text(doc, "provider", false) == "unsplash") {
                        string identity = WallpaperOcs.text(doc, "id");
                        if (identity != "" && identity.length <= 64 && !new Regex("[^A-Za-z0-9_-]").match(identity))
                            result.add("unsplash:" + identity);
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
                string ocs_id = (provider == "openverse" || provider == "unsplash") ? WallpaperOcs.text(sidecar_doc, "id") :
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
