using Gee;

namespace Singularity {

    public enum BarSection {
        LEFT,
        CENTER,
        RIGHT
    }

    public class BarLayout : Object {
        private string[] allowed_items;
        private ArrayList<string> left_items = new ArrayList<string>();
        private ArrayList<string> center_items = new ArrayList<string>();
        private ArrayList<string> right_items = new ArrayList<string>();

        public BarLayout(
            string[] allowed_items,
            string[] default_left,
            string[] default_center,
            string[] default_right,
            string[] saved_left,
            string[] saved_center,
            string[] saved_right
        ) {
            this.allowed_items = allowed_items;
            var allowed = new HashSet<string>();
            var seen = new HashSet<string>();
            foreach (string item in allowed_items) allowed.add(item);

            append_valid(left_items, saved_left, allowed, seen);
            append_valid(center_items, saved_center, allowed, seen);
            append_valid(right_items, saved_right, allowed, seen);
            append_missing(left_items, default_left, allowed, seen);
            append_missing(center_items, default_center, allowed, seen);
            append_missing(right_items, default_right, allowed, seen);

            foreach (string item in allowed_items) {
                if (seen.add(item)) center_items.add(item);
            }
        }

        private static void append_valid(
            ArrayList<string> target,
            string[] source,
            HashSet<string> allowed,
            HashSet<string> seen
        ) {
            foreach (string item in source) {
                if (allowed.contains(item) && seen.add(item)) target.add(item);
            }
        }

        private static void append_missing(
            ArrayList<string> target,
            string[] defaults,
            HashSet<string> allowed,
            HashSet<string> seen
        ) {
            foreach (string item in defaults) {
                if (allowed.contains(item) && seen.add(item)) target.add(item);
            }
        }

        private ArrayList<string> items_for(BarSection section) {
            switch (section) {
                case BarSection.LEFT:
                    return left_items;
                case BarSection.RIGHT:
                    return right_items;
                default:
                    return center_items;
            }
        }

        public string[] get_items(BarSection section) {
            return items_for(section).to_array();
        }

        public BarSection get_section(string item) {
            if (left_items.contains(item)) return BarSection.LEFT;
            if (right_items.contains(item)) return BarSection.RIGHT;
            return BarSection.CENTER;
        }

        public int get_index(string item) {
            return items_for(get_section(item)).index_of(item);
        }

        public bool move(string item, BarSection target_section, int target_index) {
            if (!contains(item)) return false;

            BarSection source_section = get_section(item);
            var source = items_for(source_section);
            var target = items_for(target_section);
            int source_index = source.index_of(item);
            if (source_index < 0) return false;

            string moved_item = source.remove_at(source_index);
            if (source == target && target_index > source_index) target_index--;
            target_index = int.max(0, int.min(target_index, target.size));
            target.insert(target_index, moved_item);
            return source_section != target_section || source_index != target_index;
        }

        public bool move_up(string item) {
            int index = get_index(item);
            if (index <= 0) return false;
            return move(item, get_section(item), index - 1);
        }

        public bool move_down(string item) {
            var items = items_for(get_section(item));
            int index = items.index_of(item);
            if (index < 0 || index >= items.size - 1) return false;
            return move(item, get_section(item), index + 2);
        }

        private bool contains(string item) {
            foreach (string allowed in allowed_items) {
                if (allowed == item) return true;
            }
            return false;
        }
    }
}
