// Run in the desktop user's environment to report the production scanner's
// candidates against the installed registry and current GSettings history.
using GLib;
using Gee;
using Singularity;

int main(string[] args) {
    var roots = new ArrayList<string>();
    foreach (unowned string dir in Environment.get_system_data_dirs())
        roots.add(Path.build_filename(dir, "ncz-wallpapers", "collections"));
    roots.add(Path.build_filename(Environment.get_user_data_dir(), "ncz-wallpapers", "collections"));
    var collections = WallpaperCollections.parse(roots.to_array());
    var state = new WallpaperRotationState(Path.build_filename(Environment.get_user_config_dir(), "ncz-wallpaper"));
    string selected = state.get_selected_collection("ncz");
    string? root = null;
    var dirs = new ArrayList<string>();
    foreach (var collection in collections) {
        dirs.add(collection.dir);
        if (collection.id == selected) root = collection.dir;
    }
    if (root == null && collections.size > 0) root = collections[0].dir;
    var settings = new GLib.Settings("dev.sinty.desktop");
    var candidates = WallpaperGallery.scan(root, dirs.to_array(), settings.get_strv("recent-wallpapers"));
    stdout.printf("source=%s root=%s images=%d\n", selected, root ?? "(none)", candidates.size);
    foreach (var candidate in candidates)
        stdout.printf("%s\t%s\n", candidate.is_recent ? "recent" : "scan", candidate.uri);
    return 0;
}
