using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class BarLayoutEditOverlay : Gtk.Window {
        private GLib.Settings settings;

        public BarLayoutEditOverlay(Gtk.Application app, Gdk.Monitor? monitor = null) {
            Object(application: app);
            settings = new GLib.Settings("dev.sinty.desktop");

            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.TOP);
            set_namespace(this, "singularity-layout-edit");
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, 0);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            if (monitor != null) set_monitor(this, monitor);

            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("layout-edit-overlay");

            var content = new Box(Orientation.VERTICAL, 0);
            content.halign = Align.CENTER;
            content.valign = Align.CENTER;
            set_child(content);

            var save_button = new Button.with_label(_("Save Changes"));
            save_button.add_css_class("pill");
            save_button.add_css_class("suggested-action");
            save_button.add_css_class("layout-edit-save");
            save_button.clicked.connect(finish_editing);
            content.append(save_button);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, keycode, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                finish_editing();
                return true;
            });
            ((Gtk.Widget) this).add_controller(keys);
        }

        private void finish_editing() {
            settings.set_boolean("bar-layout-edit-mode", false);
        }
    }
}
