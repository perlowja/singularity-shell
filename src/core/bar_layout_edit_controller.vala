using Gtk;
using Gee;

namespace Singularity {

    public class BarLayoutEditController : Object {
        private GLib.Settings settings;
        private string key_prefix;
        private Box left_box;
        private Box center_box;
        private Box right_box;
        private HashMap<string, Gtk.Widget> items;
        private string[] item_ids;
        private string[] item_titles;
        private HashMap<string, Gtk.Button> drag_handles = new HashMap<string, Gtk.Button>();
        private Button left_add;
        private Button center_add;
        private Button right_add;
        private Box drop_placeholder;

        public signal void move_requested(string item_id, BarSection section, int index);
        public signal void edit_mode_changed(bool editing);

        public BarLayoutEditController(
            GLib.Settings settings,
            string key_prefix,
            Box left_box,
            Box center_box,
            Box right_box,
            HashMap<string, Gtk.Widget> items,
            string[] item_ids,
            string[] item_titles
        ) {
            this.settings = settings;
            this.key_prefix = key_prefix;
            this.left_box = left_box;
            this.center_box = center_box;
            this.right_box = right_box;
            this.items = items;
            this.item_ids = item_ids;
            this.item_titles = item_titles;

            left_add = create_add_button(BarSection.LEFT);
            center_add = create_add_button(BarSection.CENTER);
            right_add = create_add_button(BarSection.RIGHT);
            drop_placeholder = new Box(Orientation.VERTICAL, 0);
            drop_placeholder.add_css_class("bar-layout-drop-placeholder");
            foreach (string item_id in item_ids) {
                drag_handles[item_id] = create_drag_handle(item_id);
            }
            add_drop_target(left_box, BarSection.LEFT);
            add_drop_target(center_box, BarSection.CENTER);
            add_drop_target(right_box, BarSection.RIGHT);
            settings.changed["bar-layout-edit-mode"].connect(sync);
            sync();
        }

        public bool editing {
            get { return settings.get_boolean("bar-layout-edit-mode"); }
        }

        public void detach_controls() {
            detach(drop_placeholder);
            detach(left_add);
            detach(center_add);
            detach(right_add);
            foreach (Gtk.Button handle in drag_handles.values) detach(handle);
        }

        public void sync() {
            bool active = editing;
            detach_controls();

            foreach (string item_id in item_ids) {
                Gtk.Widget? widget = items[item_id];
                if (widget == null) continue;
                if (active && widget.parent is Box) {
                    ((Box) widget.parent).insert_child_after(drag_handles[item_id], widget);
                }
            }

            set_section_editing(left_box, active);
            set_section_editing(center_box, active);
            set_section_editing(right_box, active);
            if (active) {
                left_box.prepend(left_add);
                center_box.append(center_add);
                right_box.append(right_add);
            }
            edit_mode_changed(active);
        }

        private void set_section_editing(Box section, bool active) {
            section.visible = active || has_layout_item(section);
        }

        private bool has_layout_item(Box section) {
            Widget? child = section.get_first_child();
            while (child != null) {
                if (!is_control(child)) return true;
                child = child.get_next_sibling();
            }
            return false;
        }

        private Button create_drag_handle(string item_id) {
            var handle = new Button.from_icon_name("list-drag-handle-symbolic");
            handle.has_frame = false;
            handle.add_css_class("circular");
            handle.add_css_class("flat");
            handle.tooltip_text = _("Move item");
            handle.set_cursor_from_name("grab");
            var source = new DragSource();
            source.actions = Gdk.DragAction.MOVE;
            source.prepare.connect((x, y) => {
                if (!editing) return null;
                return new Gdk.ContentProvider.for_value(key_prefix + ":" + item_id);
            });
            source.drag_begin.connect(() => handle.set_cursor_from_name("grabbing"));
            source.drag_end.connect(() => {
                handle.set_cursor_from_name("grab");
            });
            handle.add_controller(source);
            return handle;
        }

        private bool is_control(Gtk.Widget widget) {
            if (widget == drop_placeholder) return true;
            if (widget == left_add || widget == center_add || widget == right_add) return true;
            foreach (Gtk.Button handle in drag_handles.values) {
                if (widget == handle) return true;
            }
            return false;
        }

        private void add_drop_target(Box section, BarSection target_section) {
            var target = new DropTarget(typeof(string), Gdk.DragAction.MOVE);
            var add_button = add_button_for(target_section);
            target.enter.connect((x, y) => {
                if (!editing) return 0;
                add_button.add_css_class("suggested-action");
                update_drop_placeholder(section, x, y);
                return Gdk.DragAction.MOVE;
            });
            target.motion.connect((x, y) => {
                if (!editing) return 0;
                update_drop_placeholder(section, x, y);
                return Gdk.DragAction.MOVE;
            });
            target.leave.connect(() => {
                add_button.remove_css_class("suggested-action");
                detach(drop_placeholder);
            });
            target.drop.connect((value, x, y) => {
                add_button.remove_css_class("suggested-action");
                detach(drop_placeholder);
                if (!editing) return false;
                if (!value.holds(typeof(string))) return false;
                string? payload = value.get_string();
                if (payload == null) return false;
                string prefix = key_prefix + ":";
                if (!payload.has_prefix(prefix)) return false;
                string item_id = payload.substring(prefix.length);
                int index = drop_index(section, x, y);
                GLib.Idle.add(() => {
                    if (editing) move_requested(item_id, target_section, index);
                    return GLib.Source.REMOVE;
                });
                return true;
            });
            section.add_controller(target);
        }

        private void update_drop_placeholder(Box section, double x, double y) {
            int index = drop_index(section, x, y);
            detach(drop_placeholder);
            if (section.orientation == Orientation.HORIZONTAL) {
                drop_placeholder.orientation = Orientation.VERTICAL;
                drop_placeholder.set_size_request(4, 24);
            } else {
                drop_placeholder.orientation = Orientation.HORIZONTAL;
                drop_placeholder.set_size_request(24, 4);
            }

            Widget? before = layout_item_at(section, index);
            if (before == null) {
                Widget? anchor = last_item_or_handle(section);
                if (anchor != null) {
                    section.insert_child_after(drop_placeholder, anchor);
                } else if (section == left_box) {
                    section.insert_child_after(drop_placeholder, left_add);
                } else {
                    section.prepend(drop_placeholder);
                }
            } else {
                Widget? previous = before.get_prev_sibling();
                if (previous == null) section.prepend(drop_placeholder);
                else section.insert_child_after(drop_placeholder, previous);
            }
        }

        private Widget? layout_item_at(Box section, int target_index) {
            int index = 0;
            Widget? child = section.get_first_child();
            while (child != null) {
                if (!is_control(child)) {
                    if (index == target_index) return child;
                    index++;
                }
                child = child.get_next_sibling();
            }
            return null;
        }

        private Widget? last_item_or_handle(Box section) {
            Widget? anchor = null;
            Widget? child = section.get_first_child();
            while (child != null) {
                if (child != drop_placeholder
                    && child != left_add && child != center_add && child != right_add) {
                    anchor = child;
                }
                child = child.get_next_sibling();
            }
            return anchor;
        }

        private Button add_button_for(BarSection section) {
            switch (section) {
                case BarSection.LEFT:
                    return left_add;
                case BarSection.RIGHT:
                    return right_add;
                default:
                    return center_add;
            }
        }

        private int drop_index(Box section, double x, double y) {
            int index = 0;
            Widget? child = section.get_first_child();
            while (child != null) {
                if (is_control(child)) {
                    child = child.get_next_sibling();
                    continue;
                }
                Graphene.Rect bounds;
                if (child.compute_bounds(section, out bounds)) {
                    double midpoint = section.orientation == Orientation.HORIZONTAL
                        ? bounds.origin.x + bounds.size.width / 2.0
                        : bounds.origin.y + bounds.size.height / 2.0;
                    double position = section.orientation == Orientation.HORIZONTAL ? x : y;
                    if (position < midpoint) return index;
                }
                index++;
                child = child.get_next_sibling();
            }
            return index;
        }

        private Button create_add_button(BarSection section) {
            var button = new Button.from_icon_name("list-add-symbolic");
            button.has_frame = false;
            button.add_css_class("circular");
            button.add_css_class("flat");
            switch (section) {
                case BarSection.LEFT:
                    button.tooltip_text = _("Add or move an item to the left");
                    break;
                case BarSection.RIGHT:
                    button.tooltip_text = _("Add or move an item to the right");
                    break;
                default:
                    button.tooltip_text = _("Add or move an item to the center");
                    break;
            }
            button.clicked.connect(() => show_item_picker(button, section));
            return button;
        }

        private void show_item_picker(Button button, BarSection section) {
            var popover = new Popover();
            var list = new Box(Orientation.VERTICAL, 2);
            list.margin_top = 6;
            list.margin_bottom = 6;
            list.margin_start = 6;
            list.margin_end = 6;

            for (int i = 0; i < item_ids.length; i++) {
                string item_id = item_ids[i];
                if (items[item_id] == null) continue;
                list.append(create_picker_item(popover, item_id, item_titles[i]));
            }
            popover.set_child(list);
            popover.set_parent(button);
            popover.closed.connect(() => {
                unowned string? selected_item_id = popover.get_data<string>("selected-item-id");
                string? item_id = selected_item_id?.dup();
                popover.unparent();
                if (item_id == null) return;
                string move_item_id = item_id;
                GLib.Idle.add(() => {
                    if (editing) move_requested(move_item_id, section, int.MAX);
                    return GLib.Source.REMOVE;
                });
            });
            popover.popup();
        }

        private Button create_picker_item(Popover popover, string item_id, string title) {
            var button = new Button.with_label(title);
            button.has_frame = false;
            button.halign = Align.FILL;
            button.clicked.connect(() => {
                popover.set_data<string>("selected-item-id", item_id);
                popover.popdown();
            });
            return button;
        }

        private void detach(Gtk.Widget widget) {
            if (widget.parent is Box) ((Box) widget.parent).remove(widget);
        }

    }
}
