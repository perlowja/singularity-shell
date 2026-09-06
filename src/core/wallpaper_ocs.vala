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
        public string key { owned get { return provider + ":" + id; } }
    }
    public class WallpaperOcs : Object {
        public static ArrayList<WallpaperOcsChoice> providers(string data) throws Error { return new ArrayList<WallpaperOcsChoice>(); }
        public static ArrayList<WallpaperOcsChoice> categories(string data, string provider) throws Error { return new ArrayList<WallpaperOcsChoice>(); }
        public static ArrayList<WallpaperOcsItem> items(string data, string provider, string category) throws Error { return new ArrayList<WallpaperOcsItem>(); }
    }
    public class WallpaperOcsImports : Object {
        public bool busy { get; private set; default = false; }
        public bool begin(string key) { return false; }
        public void fail(string key) {}
        public bool is_added(string key) { return false; }
        public void discover(ArrayList<WallpaperCollectionInfo> collections) {}
        public void complete(string key, string data, string[] roots) throws Error {}
    }
}
