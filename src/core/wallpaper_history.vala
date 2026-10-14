using GLib;
using Gee;

namespace Singularity {

    public class WallpaperHistory : Object {
        public const int MAX_ENTRIES = 200;
        private const string GROUP = "History";

        private string path;
        private ArrayList<string> back = new ArrayList<string>();
        private ArrayList<string> forward = new ArrayList<string>();
        private int max_entries;
        public string? current_path { get; private set; default = null; }
        public int size { get { return back.size + forward.size + (current_path != null ? 1 : 0); } }

        public WallpaperHistory(string path, int max_entries = MAX_ENTRIES) {
            this.path = path;
            this.max_entries = int.max(1, max_entries);
            load();
        }

        private void load_stack(KeyFile file, ArrayList<string> destination, string key) {
            try {
                foreach (string entry in file.get_string_list(GROUP, key)) {
                    if (entry != "") destination.add(entry);
                }
            } catch (Error e) {
            }
        }

        private void load() {
            var file = new KeyFile();
            try {
                file.load_from_file(path, KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            load_stack(file, back, "back");
            load_stack(file, forward, "forward");
            try {
                string saved = file.get_string(GROUP, "current");
                if (saved != "") current_path = saved;
            } catch (Error e) {
            }
            trim_to_limit();
        }

        private string[] stack_to_array(ArrayList<string> stack) {
            string[] result = {};
            foreach (string entry in stack) result += entry;
            return result;
        }

        private void save() {
            var file = new KeyFile();
            file.set_string_list(GROUP, "back", stack_to_array(back));
            file.set_string_list(GROUP, "forward", stack_to_array(forward));
            file.set_string(GROUP, "current", current_path ?? "");
            try {
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, file.to_data());
            } catch (Error e) {
                warning("Wallpaper history could not be saved: %s", e.message);
            }
        }

        private void trim_to_limit() {
            while (size > max_entries) {
                if (back.size > 0) back.remove_at(0);
                else if (forward.size > 0) forward.remove_at(0);
                else break;
            }
        }

        public void record(string entry) {
            if (entry == "" || entry == current_path) return;
            if (current_path != null) back.add(current_path);
            current_path = entry;
            forward.clear();
            trim_to_limit();
            save();
        }

        public bool can_go_back() {
            return current_path != null && back.size > 0;
        }

        public bool can_go_forward() {
            return current_path != null && forward.size > 0;
        }

        public string? go_back() {
            if (!can_go_back()) return null;
            forward.add(current_path);
            current_path = back.remove_at(back.size - 1);
            save();
            return current_path;
        }

        public string? go_forward() {
            if (!can_go_forward()) return null;
            back.add(current_path);
            current_path = forward.remove_at(forward.size - 1);
            save();
            return current_path;
        }
    }
}
