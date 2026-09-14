using Gtk;
using Singularity.Widgets;

namespace Singularity {

    private Gdk.RGBA fan_theme_color(Widget widget, string name, string fallback) {
        Gdk.RGBA color = Gdk.RGBA();
        if (!widget.get_style_context().lookup_color(name, out color)) color.parse(fallback);
        return color;
    }

    private class FanLegendDot : DrawingArea {
        private Gdk.RGBA? color = null;
        private string color_name;
        private string fallback;

        public FanLegendDot(string color_name, string fallback) {
            this.color_name = color_name;
            this.fallback = fallback;
            set_size_request(10, 10);
            valign = Align.CENTER;
            set_draw_func((area, cr, w, h) => {
                var c = color ?? fan_theme_color(this, this.color_name, this.fallback);
                Gdk.cairo_set_source_rgba(cr, c);
                cr.arc(w / 2.0, h / 2.0, 4, 0, 2 * Math.PI);
                cr.fill();
            });
        }
    }

    public class FanHistoryGraph : Box {
        public const int HISTORY_SIZE = 150;
        private Overlay plot;
        private SparkLine rpm_line;
        private SparkLine temp_line;
        private int[] rpm_history = {};
        private double rpm_scale = 1000;
        private Label rpm_label;
        private Label temp_label;

        public FanHistoryGraph() {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            margin_top = 10;
            margin_bottom = 10;
            margin_start = 12;
            margin_end = 12;

            plot = new Overlay();
            plot.set_size_request(-1, 110);
            plot.overflow = Overflow.HIDDEN;
            rpm_line = new SparkLine(HISTORY_SIZE);
            plot.set_child(rpm_line);
            temp_line = new SparkLine(HISTORY_SIZE, "#e5a50a", "rgba(0,0,0,0)");
            temp_line.can_target = false;
            plot.add_overlay(temp_line);
            append(plot);

            var legend = new Box(Orientation.HORIZONTAL, 6);
            legend.append(new FanLegendDot("accent_color", "#3584e4"));
            rpm_label = new Label(_("Fan speed"));
            rpm_label.add_css_class("caption");
            legend.append(rpm_label);
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.set_size_request(12, -1);
            legend.append(spacer);
            legend.append(new FanLegendDot("warning_color", "#e5a50a"));
            temp_label = new Label(_("Temperature"));
            temp_label.add_css_class("caption");
            legend.append(temp_label);
            var window_label = new Label(_("Last 5 minutes"));
            window_label.add_css_class("caption");
            window_label.add_css_class("dim-label");
            window_label.hexpand = true;
            window_label.halign = Align.END;
            legend.append(window_label);
            append(legend);

            realize.connect(() => {
                temp_line.set_color(fan_theme_color(this, "warning_color", "#e5a50a").to_string());
            });
        }

        public void push(int rpm, int millidegrees, double heat_fraction) {
            rpm_history += rpm;
            if (rpm_history.length > HISTORY_SIZE) rpm_history = rpm_history[rpm_history.length - HISTORY_SIZE:rpm_history.length];
            if (rpm > rpm_scale) {
                rpm_scale = Math.ceil(rpm * 1.2 / 500.0) * 500.0;
                var line = new SparkLine(HISTORY_SIZE);
                foreach (int value in rpm_history) line.push(value / rpm_scale);
                plot.set_child(line);
                rpm_line = line;
            } else {
                rpm_line.push(rpm / rpm_scale);
            }
            temp_line.push(heat_fraction);
            rpm_label.label = _("Fan %d RPM").printf(rpm);
            temp_label.label = millidegrees > 0
                ? _("CPU %d °C").printf(millidegrees / 1000)
                : _("Temperature");
        }
    }

    public class FanCurveEditor : DrawingArea {
        private const double PAD_LEFT = 34;
        private const double PAD_RIGHT = 10;
        private const double PAD_TOP = 10;
        private const double PAD_BOTTOM = 22;
        private const int MIN_TEMP = 20000;
        private const int POINT_GAP = 2000;
        private const int CRIT_MARGIN = 5000;

        public int[] temps = {};
        public int[] percents = {};
        public int crit_millidegrees { get; set; default = 100000; }
        public int min_percent { get; set; default = 20; }
        public bool editable { get; set; default = true; }
        public int live_millidegrees { get; set; default = -1; }

        private int drag_index = -1;
        private double drag_start_x;
        private double drag_start_y;

        public signal void changed();

        public FanCurveEditor(bool editable) {
            this.editable = editable;
            set_size_request(-1, 170);
            hexpand = true;
            margin_top = 10;
            margin_bottom = 6;
            margin_start = 12;
            margin_end = 12;
            set_draw_func(draw);
            notify["live-millidegrees"].connect(() => queue_draw());

            var drag = new GestureDrag();
            drag.drag_begin.connect((x, y) => {
                drag_index = editable ? nearest_point(x, y) : -1;
                drag_start_x = x;
                drag_start_y = y;
                if (drag_index >= 0) drag.set_state(EventSequenceState.CLAIMED);
            });
            drag.drag_update.connect((dx, dy) => {
                if (drag_index < 0) return;
                move_point(drag_index, drag_start_x + dx, drag_start_y + dy);
            });
            drag.drag_end.connect(() => {
                drag_index = -1;
                queue_draw();
            });
            add_controller(drag);
        }

        public int ceiling {
            get { return crit_millidegrees - CRIT_MARGIN; }
        }

        public void set_points(int[] new_temps, int[] new_percents) {
            temps = new_temps;
            percents = new_percents;
            queue_draw();
        }

        public void add_point() {
            int n = temps.length;
            int widest = 0;
            for (int i = 1; i < n - 1; i++) {
                if (temps[i + 1] - temps[i] > temps[widest + 1] - temps[widest]) widest = i;
            }
            if (temps[widest + 1] - temps[widest] < POINT_GAP * 2) return;
            int temp = (temps[widest] + temps[widest + 1]) / 2 / 1000 * 1000;
            int percent = (percents[widest] + percents[widest + 1]) / 2;
            int[] t = {};
            int[] p = {};
            for (int i = 0; i < n; i++) {
                t += temps[i];
                p += percents[i];
                if (i == widest) {
                    t += temp;
                    p += percent;
                }
            }
            set_points(t, p);
            changed();
        }

        public void remove_point() {
            int n = temps.length;
            int tightest = 1;
            for (int i = 1; i < n - 1; i++) {
                if (temps[i + 1] - temps[i - 1] < temps[tightest + 1] - temps[tightest - 1]) tightest = i;
            }
            int[] t = {};
            int[] p = {};
            for (int i = 0; i < n; i++) {
                if (i == tightest) continue;
                t += temps[i];
                p += percents[i];
            }
            set_points(t, p);
            changed();
        }

        public int percent_at(int millidegrees) {
            int n = temps.length;
            if (n == 0) return 0;
            if (millidegrees <= temps[0]) return percents[0];
            for (int i = 1; i < n; i++) {
                if (millidegrees <= temps[i]) {
                    double f = (double) (millidegrees - temps[i - 1]) / (temps[i] - temps[i - 1]);
                    return (int) Math.round(percents[i - 1] + f * (percents[i] - percents[i - 1]));
                }
            }
            return percents[n - 1];
        }

        private double plot_width() {
            return get_width() - PAD_LEFT - PAD_RIGHT;
        }

        private double plot_height() {
            return get_height() - PAD_TOP - PAD_BOTTOM;
        }

        private double x_of(int millidegrees) {
            double span = crit_millidegrees - MIN_TEMP;
            return PAD_LEFT + (millidegrees - MIN_TEMP) / span * plot_width();
        }

        private double y_of(int percent) {
            return PAD_TOP + (1.0 - percent / 100.0) * plot_height();
        }

        private int nearest_point(double x, double y) {
            int best = -1;
            double best_distance = 18 * 18;
            for (int i = 0; i < temps.length; i++) {
                double dx = x_of(temps[i]) - x;
                double dy = y_of(percents[i]) - y;
                double distance = dx * dx + dy * dy;
                if (distance < best_distance) {
                    best_distance = distance;
                    best = i;
                }
            }
            return best;
        }

        private void move_point(int index, double x, double y) {
            int n = temps.length;
            double span = crit_millidegrees - MIN_TEMP;
            int temp = (int) Math.round((MIN_TEMP + (x - PAD_LEFT) / plot_width() * span) / 1000.0) * 1000;
            int percent = (int) Math.round((1.0 - (y - PAD_TOP) / plot_height()) * 100.0);
            int low_temp = index > 0 ? temps[index - 1] + POINT_GAP : MIN_TEMP;
            int high_temp = index < n - 1 ? temps[index + 1] - POINT_GAP : ceiling;
            int low_percent = index > 0 ? percents[index - 1] : min_percent;
            int high_percent = index < n - 1 ? percents[index + 1] : 100;
            temps[index] = temp.clamp(low_temp, int.min(high_temp, ceiling));
            percents[index] = percent.clamp(int.max(low_percent, min_percent), high_percent);
            queue_draw();
            changed();
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            var fg = get_color();
            var accent = fan_theme_color(this, "accent_color", "#3584e4");
            var danger = fan_theme_color(this, "error_color", "#e01b24");
            double left = PAD_LEFT;
            double right = width - PAD_RIGHT;
            double top = PAD_TOP;
            double bottom = height - PAD_BOTTOM;

            cr.set_line_width(1);
            cr.select_font_face("sans-serif", Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
            cr.set_font_size(10);
            for (int percent = 0; percent <= 100; percent += 25) {
                double y = y_of(percent);
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.08);
                cr.move_to(left, y);
                cr.line_to(right, y);
                cr.stroke();
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.5);
                cr.move_to(2, y + 3);
                cr.show_text("%d%%".printf(percent));
            }
            for (int temp = 20000; temp <= crit_millidegrees; temp += 20000) {
                double x = x_of(temp);
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.08);
                cr.move_to(x, top);
                cr.line_to(x, bottom);
                cr.stroke();
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.5);
                cr.move_to(x - 10, height - 6);
                cr.show_text("%d°".printf(temp / 1000));
            }

            cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.06);
            cr.rectangle(left, y_of(min_percent), right - left, bottom - y_of(min_percent));
            cr.fill();
            cr.set_source_rgba(danger.red, danger.green, danger.blue, 0.12);
            cr.rectangle(x_of(ceiling), top, right - x_of(ceiling), bottom - top);
            cr.fill();

            int n = temps.length;
            if (n == 0) return;
            cr.move_to(left, bottom);
            cr.line_to(left, y_of(percents[0]));
            for (int i = 0; i < n; i++) cr.line_to(x_of(temps[i]), y_of(percents[i]));
            cr.line_to(x_of(ceiling), y_of(percents[n - 1]));
            cr.line_to(x_of(ceiling), y_of(100));
            cr.line_to(right, y_of(100));
            cr.line_to(right, bottom);
            cr.close_path();
            cr.set_source_rgba(accent.red, accent.green, accent.blue, editable ? 0.16 : 0.08);
            cr.fill();

            cr.move_to(left, y_of(percents[0]));
            for (int i = 0; i < n; i++) cr.line_to(x_of(temps[i]), y_of(percents[i]));
            cr.line_to(x_of(ceiling), y_of(percents[n - 1]));
            cr.line_to(x_of(ceiling), y_of(100));
            cr.line_to(right, y_of(100));
            cr.set_source_rgba(accent.red, accent.green, accent.blue, editable ? 1.0 : 0.6);
            cr.set_line_width(2);
            cr.set_line_join(Cairo.LineJoin.ROUND);
            cr.stroke();

            for (int i = 0; i < n; i++) {
                double radius = i == drag_index ? 7 : 5;
                cr.arc(x_of(temps[i]), y_of(percents[i]), radius, 0, 2 * Math.PI);
                cr.set_source_rgba(accent.red, accent.green, accent.blue, editable ? 1.0 : 0.6);
                cr.fill();
            }

            if (live_millidegrees > 0) {
                int live = live_millidegrees.clamp(MIN_TEMP, crit_millidegrees);
                double x = x_of(live);
                int live_percent = live >= ceiling ? 100 : int.max(percent_at(live), min_percent);
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.45);
                cr.set_line_width(1);
                cr.set_dash({ 3, 3 }, 0);
                cr.move_to(x, top);
                cr.line_to(x, bottom);
                cr.stroke();
                cr.set_dash(null, 0);
                cr.arc(x, y_of(live_percent), 3.5, 0, 2 * Math.PI);
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.9);
                cr.fill();
            }

            if (drag_index >= 0) {
                string text = "%d °C  %d%%".printf(temps[drag_index] / 1000, percents[drag_index]);
                Cairo.TextExtents extents;
                cr.text_extents(text, out extents);
                double tx = (x_of(temps[drag_index]) - extents.width / 2).clamp(left, right - extents.width);
                double ty = double.max(top + 12, y_of(percents[drag_index]) - 12);
                cr.set_source_rgba(fg.red, fg.green, fg.blue, 0.9);
                cr.move_to(tx, ty);
                cr.show_text(text);
            }
        }
    }
}
