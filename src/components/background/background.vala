using Gtk;
using GtkLayerShell;
// GLib.Markup.escape_text -- used by the attribution overlay to safely
// embed third-party OCS/Bing caption text in a Pango-markup Label.
using GLib;

namespace Singularity {

    public class Background : Gtk.Window {
        private Picture picture_a;
        private Picture picture_b;
        private Stack wp_stack;
        private bool _wp_showing_a = true;
        private uint _wp_clear_id = 0;
        // Live-toggle for the attribution overlay. Background.vala reads
        // show-wallpaper-attribution and routes through the existing
        // empty-title-and-empty-author early-return path when false, so
        // toggling it live (via the desktop settings page) hides or
        // re-shows the overlay without waiting for the next wallpaper
        // change. The schema id matches the rest of the shell
        // (desktop_page.vala initialises the same way).
        private GLib.Settings settings;

        // Attribution overlay. wp_stack is the wallpaper cross-fade;
        // the attribution Label sits on top of it in a Gtk.Overlay so
        // the wallpaper texture is the lower layer and the text is
        // painted over the corner of the screen. The label is hidden
        // when both WallpaperManager.attribution_title and
        // attribution_author are empty (the schema-default state and
        // the explicit-clear state at every background-picture-uri
        // write site).
        private Gtk.Overlay? wp_overlay;
        private Label attribution_label;
        // Loads the attribution-label CSS once per process. Static +
        // null-guarded the same way panel.vala's compact_rows_provider is,
        // since Background windows are created per-monitor and the rules
        // are process-global, not per-instance.
        private static Gtk.CssProvider? attribution_css_provider = null;
        // Pixel margin from the screen edge to the attribution label.
        // Either bottom corner is clear of the dock (which is bottom-anchored
        // and horizontally centered) at any reasonable screen width,
        // but a 24px gutter keeps the scrim from clipping into the
        // screen edge on rounded displays / ultrawide aspects.
        private const int ATTRIBUTION_MARGIN = 24;

        public signal void first_painted();
        private bool _first_painted_done = false;

        public Background(Gtk.Application app, Gdk.Monitor? monitor = null) {
            Object(application: app);
            init_for_window(this);
            if (monitor != null) {
                GtkLayerShell.set_monitor(this, monitor);
            }
            set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("background-window");
            ensure_attribution_css();

            picture_a = new Picture();
            picture_a.content_fit = ContentFit.COVER;
            picture_b = new Picture();
            picture_b.content_fit = ContentFit.COVER;

            wp_stack = new Stack();
            wp_stack.transition_type = StackTransitionType.CROSSFADE;
            wp_stack.transition_duration = 600;
            wp_stack.add_named(picture_a, "a");
            wp_stack.add_named(picture_b, "b");

            // Attribution overlay. The label is bottom-corner-anchored
            // (halign comes from GSettings, valign=END, ATTRIBUTION_MARGIN gutter)
            // and click-through so it never intercepts desktop mouse
            // events. can_target=false is GTK4's correct way to make a
            // widget hit-test-transparent; setting can_focus=false
            // prevents the label from grabbing Tab focus out of the
            // desktop. The scrim + padding + font live in the
            // `attribution-label` CSS class, loaded by
            // ensure_attribution_css() above.
            attribution_label = new Label("");
            attribution_label.add_css_class("attribution-label");
            attribution_label.halign = Align.START;
            attribution_label.valign = Align.END;
            attribution_label.xalign = 0.0f;
            attribution_label.yalign = 1.0f;
            attribution_label.margin_start = ATTRIBUTION_MARGIN;
            attribution_label.margin_end = ATTRIBUTION_MARGIN;
            attribution_label.margin_bottom = ATTRIBUTION_MARGIN;
            attribution_label.margin_top = ATTRIBUTION_MARGIN;
            attribution_label.visible = false;
            attribution_label.can_focus = false;
            attribution_label.can_target = false;
            wp_overlay = new Gtk.Overlay();
            wp_overlay.set_child(wp_stack);
            wp_overlay.add_overlay(attribution_label);
            set_child(wp_overlay);

            var manager = WallpaperManager.get_default();
            // GSettings backing for the attribution toggle. Same schema id
            // string as desktop_page.vala (dev.sinty.desktop). The
            // changed[] handler re-runs update_attribution() so flipping
            // the toggle in Settings immediately hides or re-shows the
            // overlay for the wallpaper that's currently displayed.
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed.connect((key) => {
                if (key == "show-wallpaper-attribution") {
                    update_attribution(WallpaperManager.get_default());
                } else if (key == "wallpaper-attribution-position") {
                    update_attribution_position();
                }
            });
            update_attribution_position();
            // First load: set both pictures to avoid flash, no animation needed
            if (manager.display_texture != null) {
                picture_a.set_paintable(manager.display_texture);
                picture_b.set_paintable(manager.display_texture);
                schedule_hidden_wallpaper_clear();
            }
            manager.wallpaper_changed.connect(() => {
                update_wallpaper(manager);
                update_attribution(manager);
            });
            // Initial bind for the case where WallpaperManager already
            // has a display_texture and attribution on startup (warm
            // restart): wallpaper_changed would not re-fire, so we
            // call update_attribution() once explicitly.
            update_attribution(manager);
            map.connect_after(() => {
                if (_first_painted_done) return;
                var clock = get_frame_clock();
                if (clock == null) {
                    GLib.Timeout.add(50, () => { emit_first_painted(); return GLib.Source.REMOVE; });
                    return;
                }
                ulong handler = 0;
                handler = clock.after_paint.connect(() => {
                    clock.disconnect(handler);
                    emit_first_painted();
                });
                queue_draw();
            });

            present();
            var click_controller = new GestureClick();
            click_controller.button = 3;
            click_controller.pressed.connect((n_press, x, y) => {
                show_context_menu(x, y);
            });
            ((Gtk.Widget)this).add_controller(click_controller);

            // Left-click on desktop, switch global menu to OS menu
            var left_click = new GestureClick();
            left_click.button = 1;
            left_click.pressed.connect((n_press, x, y) => {
                AppSystem.get_default().notify_desktop_focused();
            });
            ((Gtk.Widget)this).add_controller(left_click);
        }

        private void emit_first_painted() {
            if (_first_painted_done) return;
            _first_painted_done = true;
            first_painted();
        }

        public void play_intro() {
            wp_stack.add_css_class("wallpaper-intro");
            GLib.Timeout.add(950, () => {
                wp_stack.remove_css_class("wallpaper-intro");
                return GLib.Source.REMOVE;
            });
        }

        // Wallpaper attribution overlay (Background.vala).
        //
        // Sits in a user-selected bottom corner of the live desktop background
        // as a single Gtk.Label over the wallpaper cross-fade. The scrim
        // uses the same theme tokens, rounded shape, border, and shadow
        // language as libsingularity's dock pill, scaled for caption text.
        //
        // Moved here from libsingularity's style.css (review on
        // libsingularity#13: that stylesheet should stay limited to
        // reusable widget styling, and this rule only exists for the
        // wallpaper attribution overlay singularity-shell owns) -- rules
        // and rationale unchanged, just relocated to the actual consumer.
        private const string ATTRIBUTION_CSS = """
.background-window .attribution-label {
    background-color: @surface_overlay;
    color: @text_color;
    border-radius: 8px;
    padding: 6px 12px;
    font-size: 13px;
    font-weight: 400;
    box-shadow: 0 4px 14px alpha(@shadow_color, 0.45), 0 1px 0 alpha(@text_color, 0.3) inset;
    border: 1px solid alpha(@text_color, 0.03);
}
""";

        // Registers ATTRIBUTION_CSS once per process, the same way
        // panel.vala's compact_rows_provider is registered: a static
        // nullable CssProvider, guarded by a null-check, loaded on first
        // Background construction.
        private static void ensure_attribution_css() {
            if (attribution_css_provider != null) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            attribution_css_provider = new Gtk.CssProvider();
            attribution_css_provider.load_from_string(ATTRIBUTION_CSS);
            Gtk.StyleContext.add_provider_for_display(
                display,
                attribution_css_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        }

        // Bind the attribution overlay to the WallpaperManager. Called
        // on every wallpaper_changed signal -- which now fires on URI
        // changes AND on attribution-only changes (see WallpaperManager
        // reload()), so a single signal covers both cases.
        //
        // Text format: title (bold) and author (dim-label) concatenated
        // with a middle-dot separator. Markup-escape both because the
        // data comes from third-party OCS / Bing caption strings that
        // the parsers accept leniently -- an unescaped & < > in the
        // text would otherwise be a Pango parse error and crash the
        // label render.
        private void update_attribution(WallpaperManager manager) {
            string title = manager.attribution_title ?? "";
            string author = manager.attribution_author ?? "";
            // The user-toggleable show-wallpaper-attribution gsettings key
            // shares the same early-return path as the no-title-and-no-author
            // case below.
            if (!settings.get_boolean("show-wallpaper-attribution")) {
                title = "";
                author = "";
            }
            if (title == "" && author == "") {
                attribution_label.visible = false;
                attribution_label.label = "";
                return;
            }

            string safe_title = Markup.escape_text(title, -1);
            string safe_author = Markup.escape_text(author, -1);
            string markup;
            if (title != "" && author != "") {
                // Two lines, not one wide line joined by a separator: a long
                // title+author pair on a single line can reach far enough
                // right to overlap the bottom-anchored, horizontally
                // centered dock -- operator feedback, 2026-09-13 live
                // review. Stacking narrows the footprint at the cost of one
                // extra line of height, which ATTRIBUTION_MARGIN already
                // accounts for from the screen edge.
                markup = "<b>%s</b>
%s".printf(safe_title, safe_author);
            } else if (title != "") {
                markup = "<b>%s</b>".printf(safe_title);
            } else {
                markup = safe_author;
            }

            // CSS class is not a supported Pango span attribute.
            attribution_label.set_markup(markup);
            attribution_label.visible = true;
        }

        private void update_attribution_position() {
            string position = settings.get_string("wallpaper-attribution-position");
            attribution_label.halign = position == "right" ? Align.END : Align.START;
            // Gtk.Overlay keeps its current child allocation when only the
            // alignment changes, so explicitly request a fresh allocation for
            // live GSettings changes to move the label immediately.
            attribution_label.queue_allocate();
        }

        private void update_wallpaper(WallpaperManager manager) {
            if (manager.display_texture == null) return;
            // Write to the off-screen picture, then crossfade to it
            if (_wp_showing_a) {
                picture_b.set_paintable(manager.display_texture);
                wp_stack.visible_child_name = "b";
            } else {
                picture_a.set_paintable(manager.display_texture);
                wp_stack.visible_child_name = "a";
            }
            _wp_showing_a = !_wp_showing_a;
            schedule_hidden_wallpaper_clear();
        }

        private void schedule_hidden_wallpaper_clear() {
            if (_wp_clear_id != 0) {
                GLib.Source.remove(_wp_clear_id);
                _wp_clear_id = 0;
            }
            bool showing_a = _wp_showing_a;
            _wp_clear_id = GLib.Timeout.add(650, () => {
                _wp_clear_id = 0;
                if (showing_a == _wp_showing_a) {
                    if (_wp_showing_a) picture_b.set_paintable(null);
                    else picture_a.set_paintable(null);
                }
                return GLib.Source.REMOVE;
            });
        }

        private void show_context_menu(double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(this);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item("Set Background", "preferences-desktop-wallpaper-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("background");
            });
            menu.add_item("Settings", "emblem-system-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("home");
            });
            menu.popup();
        }
    }
}
