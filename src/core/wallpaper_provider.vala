using GLib;
using Gee;

namespace Singularity {

    /**
     * The built-in, always-local wallpaper provider. Browses whatever
     * wallpaper collections are already installed on disk (see
     * WallpaperCollections) -- no network, no external helper process.
     *
     * This is the ONLY provider active by default: it is registered
     * directly at startup (main.vala), not through the plugin system.
     * Every other provider (OCS networks, Bing, stock photo search, ...)
     * ships as a builtin plugin that is disabled until the user opts in --
     * see WallpaperProviderRegistry.
     */
    public class SingularityWallpaperProvider : Object, WallpaperProvider {
        public string id { get { return "singularity"; } }
        public string display_name { owned get { return _("Singularity"); } }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }

        public async ArrayList<WallpaperProviderChoice> choices(string category_index,
                Cancellable? cancel) throws Error {
            var result = new ArrayList<WallpaperProviderChoice>();
            foreach (var collection in WallpaperCollections.parse(WallpaperCollections.default_search_roots()))
                result.add(new WallpaperProviderChoice(collection.id, collection.name));
            return result;
        }

        public async WallpaperProviderResult browse(string choice_id, string query, int page,
                bool force_refresh, Cancellable? cancel) throws Error {
            var collections = WallpaperCollections.parse(WallpaperCollections.default_search_roots());
            WallpaperCollectionInfo? selected = null;
            var all_dirs = new ArrayList<string>();
            foreach (var collection in collections) {
                all_dirs.add(collection.dir);
                if (collection.id == choice_id) selected = collection;
            }
            var result = new WallpaperProviderResult();
            if (selected == null) return result;
            foreach (var candidate in WallpaperGallery.scan(selected.dir, all_dirs.to_array(), {})) {
                var item = new WallpaperItem();
                item.provider_id = id;
                item.id = candidate.uri;
                item.name = selected.name;
                item.author = selected.artist;
                item.thumbnail_path = File.new_for_uri(candidate.uri).get_path() ?? "";
                result.items.add(item);
            }
            return result;
        }

        public async string import_item(WallpaperItem item, Cancellable? cancel) throws Error {
            throw new IOError.NOT_SUPPORTED("Singularity wallpapers are already installed locally.");
        }
    }
}
