using Singularity;
using GLib;
using Gee;

namespace Singularity {

    private class ScrollingWorkarea : Object {
        public int x;
        public int y;
        public int width;
        public int height;

        public ScrollingWorkarea(int x, int y, int width, int height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }
    }

    private class ScrollingRect : Object {
        public int x;
        public int y;
        public int width;
        public int height;

        public ScrollingRect(int x, int y, int width, int height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }
    }

    private class ScrollingColumn : Object {
        public ArrayList<AppSystem.Window> windows =
            new ArrayList<AppSystem.Window>();
        public int width;

        public ScrollingColumn(int width) {
            this.width = width;
        }
    }

    private class ScrollingGroup : Object {
        public string key;
        public ScrollingWorkarea area;
        public Gdk.Monitor? monitor;
        public ArrayList<ScrollingColumn> columns =
            new ArrayList<ScrollingColumn>();
        public AppSystem.Window? focused;
        public AppSystem.Window? interaction_window;
        public ScrollingColumn? drag_column;
        public ScrollingColumn? stack_column;
        public double offset = 0;
        public uint offset_animation_id = 0;
        public double offset_animation_start = 0;
        public double offset_animation_target = 0;
        public int64 offset_animation_started = 0;
        public bool initialized = false;

        public ScrollingGroup(string key, ScrollingWorkarea area,
                              Gdk.Monitor? monitor) {
            this.key = key;
            this.area = area;
            this.monitor = monitor;
        }
    }

    private class StackTarget : Object {
        public ScrollingColumn column;
        public int index;
        public int distance;

        public StackTarget(ScrollingColumn column, int index, int distance) {
            this.column = column;
            this.index = index;
            this.distance = distance;
        }
    }

    public class TilingManager : Object {
        private const int MIN_COLUMN_WIDTH = 240;
        private const int STACK_TARGET_SIZE = 30;
        private const int GESTURE_ADVANCE_DISTANCE = 48;
        private const uint OFFSET_SETTLE_DURATION = 180;
        private static TilingManager? instance;
        private AppSystem app_system;
        private GLib.Settings settings;
        private bool enabled = true;
        private bool shell_overview_active = false;
        private uint apply_timeout_id = 0;
        private HashMap<string, ScrollingGroup> scrolling_groups =
            new HashMap<string, ScrollingGroup>();
        private ScrollingGroup? gesture_group;
        private AppSystem.Window? gesture_start_window;
        private double gesture_start_offset = 0;
        private double gesture_last_dx = 0;

        public signal void scrolling_position_changed(Gdk.Monitor? monitor,
            double position, double visible_fraction, bool active);

        public static TilingManager? get_default() {
            return instance;
        }

        public TilingManager(AppSystem app_system) {
            instance = this;
            this.app_system = app_system;
            settings = new GLib.Settings("dev.sinty.desktop");
            enabled = settings.get_boolean("tiling-enabled");
            settings.changed["tiling-enabled"].connect(on_mode_changed);
            settings.changed["tiling-layout"].connect(on_mode_changed);
            settings.changed["tiling-column-width"].connect(() => {
                foreach (var group in scrolling_groups.values) {
                    foreach (var column in group.columns) column.width = 0;
                    group.initialized = false;
                }
                if (scrolling_active()) schedule_apply_layout();
            });
            settings.changed["tiling-gap"].connect(() => {
                foreach (var group in scrolling_groups.values)
                    group.initialized = false;
                if (scrolling_active()) schedule_apply_layout();
            });
            app_system.config_changed.connect((key) => {
                if (key == "dock-position" || key == "dock-enabled"
                        || key == "dock-autohide"
                        || key == "dock-intellihide") {
                    if (scrolling_active()) schedule_apply_layout();
                }
            });
            app_system.app_opened.connect(on_app_opened);
            app_system.app_closed.connect(on_app_closed);
            app_system.workspaces_changed.connect(on_workspaces_changed);
            app_system.window_focused.connect(on_window_focused);
            app_system.window_output_changed.connect(on_window_output_changed);
            app_system.any_maximized_changed.connect(on_window_state_changed);
            app_system.any_fullscreen_changed.connect(on_window_state_changed);
            Singularity.wayland_set_tiling_interaction_callback(
                on_tiling_interaction, this);
            sync_compositor_mode();
            if (enabled) schedule_apply_layout();
        }

        private bool scrolling_active() {
            return enabled && settings.get_string("tiling-layout") == "scrolling";
        }

        private int scroll_gap() {
            return settings.get_int("tiling-gap").clamp(0, 64);
        }

        private void sync_compositor_mode() {
            Singularity.wayland_set_scrolling_mode(scrolling_active() ? 1u : 0u);
        }

        private void on_mode_changed() {
            enabled = settings.get_boolean("tiling-enabled");
            bool is_scrolling = scrolling_active();
            sync_compositor_mode();
            hide_drop_preview();
            if (!is_scrolling && scrolling_groups.size > 0)
                release_scrolling_windows();
            if (enabled) schedule_apply_layout();
        }

        public void set_shell_overview_active(bool active) {
            if (shell_overview_active == active) return;
            shell_overview_active = active;
            if (!active && scrolling_active()) schedule_apply_layout();
        }

        public void refresh_scrolling_position() {
            bool emitted = false;
            foreach (var group in scrolling_groups.values) {
                emit_position(group);
                emitted = true;
            }
            if (!emitted) {
                if (scrolling_active()) schedule_apply_layout();
                else scrolling_position_changed(null, 0, 1, false);
            }
        }

        private void schedule_apply_layout() {
            if (apply_timeout_id != 0) GLib.Source.remove(apply_timeout_id);
            apply_timeout_id = GLib.Timeout.add(70, () => {
                apply_timeout_id = 0;
                apply_layout();
                return Source.REMOVE;
            }, GLib.Priority.DEFAULT_IDLE);
        }

        private void on_app_opened(void* handle, string app_id) {
            if (enabled) schedule_apply_layout();
        }

        private void on_app_closed(void* handle) {
            if (enabled) schedule_apply_layout();
        }

        private void on_workspaces_changed() {
            if (enabled) schedule_apply_layout();
        }

        private void on_window_focused(void* handle) {
            if (enabled && handle != null) schedule_apply_layout();
        }

        private void on_window_output_changed(void* handle) {
            if (enabled) schedule_apply_layout();
        }

        private void on_window_state_changed() {
            if (enabled) schedule_apply_layout();
        }

        private void snap(AppSystem.Window win, uint snap_type) {
            if (win.scrolling_tiled) {
                Singularity.wayland_set_tiled(win.handle, 0);
                win.scrolling_tiled = false;
            }
            win.scrolling_floating = false;
            Singularity.wayland_snap_view(win.handle, snap_type);
            win.snap_type = snap_type;
        }

        private ArrayList<AppSystem.Window> get_tileable_windows() {
            var tileable = new ArrayList<AppSystem.Window>();
            foreach (var win in app_system.get_active_workspace_windows()) {
                if (win.app_id == null || win.app_id == "unknown-wayland-surface")
                    continue;
                if (win.app_id.has_prefix("chrome-")
                        || win.app_id.contains(".flextop.chrome-"))
                    continue;
                if (scrolling_active() && win.scrolling_floating) continue;
                tileable.add(win);
            }
            return tileable;
        }

        private void hide_drop_preview() {
            Singularity.wayland_set_tiling_drop_preview(0, 0, 0, 0, 0);
        }

        private void cancel_offset_animation(ScrollingGroup group) {
            if (group.offset_animation_id == 0) return;
            GLib.Source.remove(group.offset_animation_id);
            group.offset_animation_id = 0;
        }

        private bool animate_offset(ScrollingGroup group, double target) {
            target = clamp_offset(group, target);
            if (Math.fabs(target - group.offset) < 0.5) {
                group.offset = target;
                return false;
            }
            cancel_offset_animation(group);
            group.offset_animation_start = group.offset;
            group.offset_animation_target = target;
            group.offset_animation_started = GLib.get_monotonic_time();
            group.offset_animation_id = GLib.Timeout.add(16, () => {
                double elapsed = (GLib.get_monotonic_time()
                    - group.offset_animation_started) / 1000.0;
                double progress = double.min(1,
                    elapsed / OFFSET_SETTLE_DURATION);
                double eased = 1 - Math.pow(1 - progress, 3);
                group.offset = group.offset_animation_start
                    + (group.offset_animation_target
                        - group.offset_animation_start) * eased;
                layout_group(group);
                if (progress >= 1) {
                    group.offset_animation_id = 0;
                    return GLib.Source.REMOVE;
                }
                return GLib.Source.CONTINUE;
            });
            return true;
        }

        private void release_scrolling_windows() {
            hide_drop_preview();
            foreach (var group in scrolling_groups.values)
                cancel_offset_animation(group);
            foreach (var win in app_system.get_windows()) {
                if (win.scrolling_tiled) {
                    Singularity.wayland_set_tiled(win.handle, 0);
                    win.scrolling_tiled = false;
                }
                win.scrolling_floating = false;
            }
            scrolling_groups.clear();
            gesture_group = null;
            scrolling_position_changed(null, 0, 1, false);
        }

        private void release_inactive_scrolling_windows(
                ArrayList<AppSystem.Window> tileable) {
            var active = new HashSet<AppSystem.Window>();
            foreach (var win in tileable) active.add(win);
            foreach (var win in app_system.get_windows()) {
                if (!win.scrolling_tiled || active.contains(win)) continue;
                Singularity.wayland_set_tiled(win.handle, 0);
                win.scrolling_tiled = false;
            }
        }

        private void apply_grid_layout(ArrayList<AppSystem.Window> tileable) {
            int count = tileable.size;
            if (count == 0) return;
            for (int i = 0; i < count; i++) {
                snap(tileable[i], TilingLayout.snap_for(count, i));
            }
        }

        private bool get_workarea(AppSystem.Window win,
                                  out int x, out int y,
                                  out int width, out int height) {
            if (Singularity.wayland_get_window_workarea(win.handle,
                    out x, out y, out width, out height)) {
                adjust_workarea_for_dock(win, ref x, ref y, ref width, ref height);
                return width > 0 && height > 0;
            }
            var monitor = Singularity.wayland_get_window_monitor(win.handle);
            if (monitor == null) {
                x = y = width = height = 0;
                return false;
            }
            var geometry = monitor.get_geometry();
            x = geometry.x;
            y = geometry.y;
            width = geometry.width;
            height = geometry.height;
            adjust_workarea_for_dock(win, ref x, ref y, ref width, ref height);
            return width > 0 && height > 0;
        }

        private void adjust_workarea_for_dock(AppSystem.Window win,
                                              ref int x, ref int y,
                                              ref int width, ref int height) {
            int dock = app_system.shell_dock_height;
            if (dock <= 0) return;
            var monitor = Singularity.wayland_get_window_monitor(win.handle);
            if (monitor == null) return;
            var geometry = monitor.get_geometry();
            string position = settings.get_string("dock-position");
            if (position == "bottom"
                    && y + height >= geometry.y + geometry.height) {
                height -= dock;
            } else if (position == "left" && x <= geometry.x) {
                x += dock;
                width -= dock;
            } else if (position == "right"
                    && x + width >= geometry.x + geometry.width) {
                width -= dock;
            }
        }

        private string workarea_key(int x, int y, int width, int height) {
            return "%d:%d:%d:%d".printf(x, y, width, height);
        }

        private int default_column_width(ScrollingGroup group) {
            int gap = scroll_gap();
            int available = int.max(1, group.area.width - 2 * gap);
            int width = group.area.width
                * settings.get_int("tiling-column-width") / 100;
            return int.min(available, int.max(MIN_COLUMN_WIDTH, width));
        }

        private int width_for(ScrollingGroup group, ScrollingColumn column) {
            if (column.width <= 0) column.width = default_column_width(group);
            int gap = scroll_gap();
            int available = int.max(MIN_COLUMN_WIDTH,
                group.area.width - 2 * gap);
            return int.min(available, int.max(MIN_COLUMN_WIDTH, column.width));
        }

        private ScrollingColumn? column_for_window(ScrollingGroup group,
                                                    AppSystem.Window win) {
            foreach (var column in group.columns) {
                if (column.windows.contains(win)) return column;
            }
            return null;
        }

        private double logical_x(ScrollingGroup group,
                                 ScrollingColumn target) {
            double x = 0;
            foreach (var column in group.columns) {
                if (column == target) return x;
                x += width_for(group, column) + scroll_gap();
            }
            return x;
        }

        private double content_width(ScrollingGroup group) {
            double width = 0;
            for (int i = 0; i < group.columns.size; i++) {
                width += width_for(group, group.columns[i]);
                if (i + 1 < group.columns.size) width += scroll_gap();
            }
            return width;
        }

        private double viewport_width(ScrollingGroup group) {
            return int.max(1, group.area.width - 2 * scroll_gap());
        }

        private void offset_limits(ScrollingGroup group,
                                   out double minimum, out double maximum) {
            double viewport = viewport_width(group);
            double content = content_width(group);
            if (group.columns.size == 0 || content <= viewport) {
                minimum = maximum = (content - viewport) / 2.0;
                return;
            }
            var first = group.columns[0];
            var last = group.columns[group.columns.size - 1];
            minimum = width_for(group, first) / 2.0 - viewport / 2.0;
            maximum = logical_x(group, last) + width_for(group, last) / 2.0
                - viewport / 2.0;
        }

        private double clamp_offset(ScrollingGroup group, double offset) {
            double minimum, maximum;
            offset_limits(group, out minimum, out maximum);
            return double.max(minimum, double.min(maximum, offset));
        }

        private double centered_offset(ScrollingGroup group,
                                       AppSystem.Window win) {
            var column = column_for_window(group, win);
            if (column == null) return group.offset;
            return logical_x(group, column) + width_for(group, column) / 2.0
                - viewport_width(group) / 2.0;
        }

        private void emit_position(ScrollingGroup group) {
            double minimum, maximum;
            offset_limits(group, out minimum, out maximum);
            double range = maximum - minimum;
            double position = range > 0.5
                ? (group.offset - minimum) / range : 0.5;
            position = double.max(0, double.min(1, position));
            double content = content_width(group);
            double fraction = content > 0
                ? double.min(1, viewport_width(group) / content) : 1;
            scrolling_position_changed(group.monitor, position, fraction,
                group.columns.size > 0 && scrolling_active());
        }

        private ScrollingRect rect_for(ScrollingGroup group,
                                       ScrollingColumn column,
                                       int row) {
            int count = int.max(1, column.windows.size);
            int total_height = int.max(count,
                group.area.height - 2 * scroll_gap()
                - (count - 1) * scroll_gap());
            int base_height = total_height / count;
            int remainder = total_height % count;
            int gap = scroll_gap();
            int y = group.area.y + gap;
            for (int i = 0; i < row; i++) {
                y += base_height + (i < remainder ? 1 : 0) + gap;
            }
            int height = base_height + (row < remainder ? 1 : 0);
            int x = group.area.x + gap
                + (int)Math.round(logical_x(group, column) - group.offset);
            return new ScrollingRect(x, y, width_for(group, column), height);
        }

        private ScrollingRect? rect_for_window(ScrollingGroup group,
                                               AppSystem.Window win) {
            var column = column_for_window(group, win);
            if (column == null) return null;
            int row = column.windows.index_of(win);
            return row >= 0 ? rect_for(group, column, row) : null;
        }

        private void layout_group(ScrollingGroup group,
                                  AppSystem.Window? skip = null) {
            foreach (var column in group.columns) {
                for (int row = 0; row < column.windows.size; row++) {
                    var win = column.windows[row];
                    if (win == skip) continue;
                    var rect = rect_for(group, column, row);
                    if (!win.scrolling_tiled) {
                        Singularity.wayland_set_tiled(win.handle, 1);
                        win.scrolling_tiled = true;
                    }
                    Singularity.wayland_set_geometry(win.handle,
                        rect.x, rect.y, rect.width, rect.height);
                    win.snap_type = TilingLayout.SNAP_NONE;
                }
            }
            emit_position(group);
        }

        private void show_drop_preview(ScrollingGroup group,
                                       AppSystem.Window win) {
            var rect = rect_for_window(group, win);
            if (rect == null) {
                hide_drop_preview();
                return;
            }
            Singularity.wayland_set_tiling_drop_preview(rect.x, rect.y,
                rect.width, rect.height, 1);
        }

        private void remove_empty_columns(ScrollingGroup group) {
            var empty = new ArrayList<ScrollingColumn>();
            foreach (var column in group.columns) {
                if (column.windows.size == 0) empty.add(column);
            }
            foreach (var column in empty) group.columns.remove(column);
        }

        private void sync_group(ScrollingGroup group,
                                ArrayList<AppSystem.Window> candidates) {
            AppSystem.Window? anchor = null;
            if (group.focused != null && candidates.contains(group.focused))
                anchor = group.focused;
            if (anchor == null) {
                foreach (var column in group.columns) {
                    foreach (var win in column.windows) {
                        if (!candidates.contains(win)) continue;
                        anchor = win;
                        break;
                    }
                    if (anchor != null) break;
                }
            }
            ScrollingRect? anchor_rect = anchor != null
                ? rect_for_window(group, anchor) : null;
            var stale = new ArrayList<AppSystem.Window>();
            foreach (var column in group.columns) {
                foreach (var win in column.windows) {
                    if (!candidates.contains(win)) stale.add(win);
                }
            }
            foreach (var win in stale) {
                var column = column_for_window(group, win);
                if (column != null) column.windows.remove(win);
                if (group.focused == win) group.focused = null;
                if (group.interaction_window == win)
                    group.interaction_window = null;
            }
            remove_empty_columns(group);
            foreach (var win in candidates) {
                if (column_for_window(group, win) != null) continue;
                var column = new ScrollingColumn(default_column_width(group));
                column.windows.add(win);
                group.columns.add(column);
            }
            if (anchor != null && anchor_rect != null) {
                var anchor_column = column_for_window(group, anchor);
                if (anchor_column != null) {
                    group.offset = group.area.x + scroll_gap()
                        + logical_x(group, anchor_column) - anchor_rect.x;
                }
            }
        }

        private AppSystem.Window? focused_in_group(ScrollingGroup group) {
            void* focused = app_system.get_focused_window_handle();
            foreach (var column in group.columns) {
                foreach (var win in column.windows) {
                    if (win.handle == focused) return win;
                }
            }
            return null;
        }

        private void apply_scrolling_layout(
                ArrayList<AppSystem.Window> tileable) {
            var candidates =
                new HashMap<string, ArrayList<AppSystem.Window>>();
            var seen_keys = new HashSet<string>();

            foreach (var win in tileable) {
                if (win.is_fullscreen || win.is_minimized) continue;
                int x, y, width, height;
                if (!get_workarea(win, out x, out y, out width, out height))
                    continue;
                string key = workarea_key(x, y, width, height);
                ScrollingGroup? group = scrolling_groups[key];
                var monitor = Singularity.wayland_get_window_monitor(win.handle);
                if (group == null) {
                    group = new ScrollingGroup(key,
                        new ScrollingWorkarea(x, y, width, height), monitor);
                    scrolling_groups[key] = group;
                } else {
                    group.area = new ScrollingWorkarea(x, y, width, height);
                    if (monitor != null) group.monitor = monitor;
                }
                if (!candidates.has_key(key))
                    candidates[key] = new ArrayList<AppSystem.Window>();
                candidates[key].add(win);
                seen_keys.add(key);
            }

            var stale_keys = new ArrayList<string>();
            foreach (var entry in scrolling_groups.entries) {
                if (!seen_keys.contains(entry.key)) {
                    cancel_offset_animation(entry.value);
                    scrolling_position_changed(entry.value.monitor, 0, 1, false);
                    stale_keys.add(entry.key);
                }
            }
            foreach (var key in stale_keys) scrolling_groups.unset(key);

            foreach (var entry in candidates.entries) {
                var group = scrolling_groups[entry.key];
                sync_group(group, entry.value);
                if (group.columns.size == 0) continue;
                if (group == gesture_group) {
                    cancel_offset_animation(group);
                    group.offset = clamp_offset(group, group.offset);
                    layout_group(group);
                    continue;
                }
                if (group.interaction_window != null
                        && column_for_window(group,
                            group.interaction_window) != null) {
                    cancel_offset_animation(group);
                    group.offset = clamp_offset(group, group.offset);
                    layout_group(group, group.interaction_window);
                    continue;
                }
                var focused = focused_in_group(group);
                bool focus_changed = focused != null && focused != group.focused;
                if (focused != null) group.focused = focused;
                if (group.focused == null
                        || column_for_window(group, group.focused) == null)
                    group.focused = group.columns[0].windows[0];
                if (!group.initialized || focus_changed) {
                    double target = centered_offset(group, group.focused);
                    bool animate = group.initialized
                        && animate_offset(group, target);
                    group.initialized = true;
                    if (animate) continue;
                    group.offset = target;
                } else {
                    group.offset = clamp_offset(group, group.offset);
                }
                layout_group(group);
            }
        }

        private ScrollingGroup? group_for_window(AppSystem.Window win) {
            foreach (var group in scrolling_groups.values) {
                if (column_for_window(group, win) != null) return group;
            }
            return null;
        }

        private ScrollingGroup? focused_group() {
            void* focused = app_system.get_focused_window_handle();
            if (focused == null) return null;
            var win = app_system.get_window_by_handle(focused);
            return win != null ? group_for_window(win) : null;
        }

        private ScrollingColumn? nearest_column(ScrollingGroup group) {
            if (group.columns.size == 0) return null;
            double viewport_center = group.offset + viewport_width(group) / 2.0;
            ScrollingColumn nearest = group.columns[0];
            double best = double.MAX;
            foreach (var column in group.columns) {
                double center = logical_x(group, column)
                    + width_for(group, column) / 2.0;
                double distance = Math.fabs(center - viewport_center);
                if (distance < best) {
                    best = distance;
                    nearest = column;
                }
            }
            return nearest;
        }

        private AppSystem.Window? nearest_window(ScrollingGroup group) {
            var nearest = nearest_column(group);
            if (nearest == null) return null;
            if (group.focused != null && nearest.windows.contains(group.focused))
                return group.focused;
            return nearest.windows[0];
        }

        public bool handle_scrolling_gesture(uint32 phase, double dx,
                                             bool cancelled) {
            if (!scrolling_active() || shell_overview_active) return false;
            if (phase == 0) {
                apply_layout();
                gesture_group = focused_group();
                if (gesture_group == null) return false;
                cancel_offset_animation(gesture_group);
                gesture_start_offset = gesture_group.offset;
                gesture_start_window = focused_in_group(gesture_group);
                gesture_last_dx = 0;
                return true;
            }
            if (gesture_group == null) return false;
            var group = gesture_group;
            if (phase == 1) {
                gesture_last_dx = dx;
                group.offset = clamp_offset(group, gesture_start_offset - dx);
                layout_group(group);
                return true;
            }
            if (phase == 2) {
                AppSystem.Window? target = gesture_start_window;
                double target_offset = gesture_start_offset;
                if (cancelled) {
                    target_offset = gesture_start_offset;
                } else {
                    var nearest = nearest_column(group);
                    var start_column = gesture_start_window != null
                        ? column_for_window(group, gesture_start_window) : null;
                    if (nearest != null && start_column != null
                            && Math.fabs(gesture_last_dx)
                                >= GESTURE_ADVANCE_DISTANCE) {
                        int nearest_index = group.columns.index_of(nearest);
                        int start_index = group.columns.index_of(start_column);
                        int target_index = nearest_index;
                        if (gesture_last_dx < 0)
                            target_index = int.max(target_index,
                                int.min(group.columns.size - 1,
                                    start_index + 1));
                        else
                            target_index = int.min(target_index,
                                int.max(0, start_index - 1));
                        var target_column = group.columns[target_index];
                        target = target_column.windows.contains(
                            gesture_start_window)
                            ? gesture_start_window : target_column.windows[0];
                    } else if (nearest != null
                            && gesture_start_window == null) {
                        target = nearest.windows[0];
                    }
                    if (target != null) {
                        group.focused = target;
                        target_offset = centered_offset(group, target);
                    }
                }
                gesture_group = null;
                gesture_start_window = null;
                gesture_last_dx = 0;
                if (!cancelled && target != null)
                    Singularity.wayland_activate_window(target.handle);
                if (animate_offset(group, target_offset)) return true;
                layout_group(group);
                return true;
            }
            return true;
        }

        private static void on_tiling_interaction(void* handle, uint32 phase,
                uint32 kind, int x, int y, int width, int height,
                int cursor_x, int cursor_y, uint32 edges,
                int float_candidate, void* data) {
            var self = (TilingManager)data;
            self.handle_tiling_interaction(handle, phase, kind,
                x, y, width, height, cursor_x, cursor_y, edges,
                float_candidate != 0);
        }

        private void prepare_drag(ScrollingGroup group,
                                  AppSystem.Window win) {
            group.stack_column = null;
            var source = column_for_window(group, win);
            if (source == null) return;
            if (source.windows.size == 1) {
                group.drag_column = source;
                return;
            }
            int source_index = group.columns.index_of(source);
            source.windows.remove(win);
            var column = new ScrollingColumn(width_for(group, source));
            column.windows.add(win);
            group.columns.insert(source_index + 1, column);
            group.drag_column = column;
        }

        private StackTarget? stack_target_at(ScrollingGroup group,
                                             AppSystem.Window win,
                                             int cursor_x, int cursor_y) {
            StackTarget? best = null;
            foreach (var column in group.columns) {
                for (int row = 0; row < column.windows.size; row++) {
                    var other = column.windows[row];
                    if (other == win) continue;
                    var rect = rect_for(group, column, row);
                    if (cursor_x < rect.x || cursor_x >= rect.x + rect.width)
                        continue;
                    int top_distance = (int)Math.fabs(cursor_y - rect.y);
                    if (top_distance <= STACK_TARGET_SIZE
                            && (best == null || top_distance < best.distance))
                        best = new StackTarget(column, row, top_distance);
                    int bottom_distance = (int)Math.fabs(
                        cursor_y - (rect.y + rect.height));
                    if (bottom_distance <= STACK_TARGET_SIZE
                            && (best == null || bottom_distance < best.distance))
                        best = new StackTarget(column, row + 1,
                            bottom_distance);
                }
            }
            return best;
        }

        private void move_to_stack(ScrollingGroup group,
                                   AppSystem.Window win,
                                   StackTarget target) {
            var source = column_for_window(group, win);
            if (source == null) return;
            var target_rect = rect_for(group, target.column, 0);
            int target_x = target_rect.x;
            int old_index = source.windows.index_of(win);
            int target_index = target.index;
            if (source == target.column && old_index < target_index)
                target_index--;
            target_index = int.max(0,
                int.min(target_index, target.column.windows.size));
            if (source == target.column && old_index == target_index) return;
            source.windows.remove(win);
            if (source.windows.size == 0) group.columns.remove(source);
            target_index = int.min(target_index, target.column.windows.size);
            target.column.windows.insert(target_index, win);
            group.offset = group.area.x + scroll_gap()
                + logical_x(group, target.column) - target_x;
            group.drag_column = target.column;
        }

        private ScrollingColumn ensure_independent_column(
                ScrollingGroup group, AppSystem.Window win,
                double dragged_center) {
            var source = column_for_window(group, win);
            if (source == null) {
                var fallback = new ScrollingColumn(default_column_width(group));
                fallback.windows.add(win);
                group.columns.add(fallback);
                return fallback;
            }
            if (source.windows.size == 1) return source;

            int width = width_for(group, source);
            source.windows.remove(win);
            var column = new ScrollingColumn(width);
            column.windows.add(win);
            int target_index = 0;
            foreach (var other in group.columns) {
                double center = group.area.x + scroll_gap()
                    + logical_x(group, other) - group.offset
                    + width_for(group, other) / 2.0;
                if (dragged_center < center) break;
                target_index++;
            }
            group.columns.insert(target_index, column);
            group.drag_column = column;
            return column;
        }

        private void reorder_drag_column(ScrollingGroup group,
                                         ScrollingColumn column,
                                         double dragged_center) {
            int old_index = group.columns.index_of(column);
            if (old_index < 0) return;
            group.columns.remove_at(old_index);
            int target_index = 0;
            double logical = 0;
            foreach (var other in group.columns) {
                double center = group.area.x + scroll_gap() + logical
                    - group.offset + width_for(group, other) / 2.0;
                if (dragged_center < center) break;
                target_index++;
                logical += width_for(group, other) + scroll_gap();
            }
            group.columns.insert(target_index, column);
        }

        private void update_drag(ScrollingGroup group,
                                 AppSystem.Window win,
                                 int x, int width,
                                 int cursor_x, int cursor_y,
                                 bool float_candidate) {
            if (float_candidate) {
                hide_drop_preview();
                layout_group(group, win);
                return;
            }
            if (group.stack_column != null) {
                var rect = rect_for(group, group.stack_column, 0);
                if (cursor_x >= rect.x
                        && cursor_x < rect.x + rect.width) {
                    layout_group(group, win);
                    show_drop_preview(group, win);
                    return;
                }
                group.stack_column = null;
            }
            var target = stack_target_at(group, win, cursor_x, cursor_y);
            if (target != null) {
                move_to_stack(group, win, target);
                group.stack_column = target.column;
            } else {
                double dragged_center = x + width / 2.0;
                var column = ensure_independent_column(group, win,
                    dragged_center);
                reorder_drag_column(group, column, dragged_center);
                group.drag_column = column;
            }
            group.offset = clamp_offset(group, group.offset);
            layout_group(group, win);
            show_drop_preview(group, win);
        }

        private void detach_floating(ScrollingGroup group,
                                     AppSystem.Window win) {
            var column = column_for_window(group, win);
            if (column != null) column.windows.remove(win);
            remove_empty_columns(group);
            win.scrolling_tiled = false;
            win.scrolling_floating = true;
            Singularity.wayland_detach_tiled(win.handle);
            if (group.columns.size == 0) {
                group.focused = null;
                scrolling_position_changed(group.monitor, 0, 1, false);
                return;
            }
            group.offset = clamp_offset(group, group.offset);
            group.focused = nearest_window(group);
            layout_group(group);
        }

        private void handle_tiling_interaction(void* handle, uint32 phase,
                uint32 kind, int x, int y, int width, int height,
                int cursor_x, int cursor_y, uint32 edges,
                bool float_candidate) {
            if (!scrolling_active() || shell_overview_active) return;
            var win = app_system.get_window_by_handle(handle);
            if (win == null) return;
            var group = group_for_window(win);
            if (group == null) {
                apply_layout();
                group = group_for_window(win);
                if (group == null) return;
            }
            if (phase == 0) {
                cancel_offset_animation(group);
                group.interaction_window = win;
                group.focused = win;
                if (kind == 0) {
                    prepare_drag(group, win);
                    group.offset = clamp_offset(group, group.offset);
                    layout_group(group, win);
                    show_drop_preview(group, win);
                }
                return;
            }
            if (kind == 1) {
                var column = column_for_window(group, win);
                if (column == null) return;
                column.width = int.min(
                    int.max(MIN_COLUMN_WIDTH, group.area.width - 2 * scroll_gap()),
                    int.max(MIN_COLUMN_WIDTH, width));
                double logical = logical_x(group, column);
                group.offset = group.area.x + scroll_gap() + logical - x;
                group.offset = clamp_offset(group, group.offset);
                layout_group(group, phase == 1 ? win : null);
                if (phase == 2) group.interaction_window = null;
                return;
            }

            if (phase == 1)
                update_drag(group, win, x, width, cursor_x, cursor_y,
                    float_candidate);
            if (phase != 2) return;

            hide_drop_preview();
            group.interaction_window = null;
            group.drag_column = null;
            group.stack_column = null;
            if (float_candidate) {
                detach_floating(group, win);
            } else {
                group.focused = win;
                if (animate_offset(group, centered_offset(group, win)))
                    return;
                layout_group(group);
            }
        }

        public void apply_layout() {
            if (scrolling_active() && shell_overview_active) return;
            var tileable = get_tileable_windows();
            if (scrolling_active()) {
                release_inactive_scrolling_windows(tileable);
                apply_scrolling_layout(tileable);
            } else {
                release_scrolling_windows();
                if (enabled) apply_grid_layout(tileable);
            }
        }
    }
}
