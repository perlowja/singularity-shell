using Gtk;

namespace Singularity {

    public class UpdateIndicator : Gtk.Button {
        private const string SOCKET = "/run/updated.sock";
        private const uint POLL_SECONDS = 45;

        private Gtk.Image icon;
        private string state = "idle";
        private string latest = "";
        private int percent = 0;
        private uint poll_id = 0;
        private uint interval = 0;
        private bool polling = false;

        public UpdateIndicator () {
            add_css_class ("dock-update-indicator");
            add_css_class ("flat");
            icon = new Gtk.Image ();
            set_child (icon);
            visible = false;
            clicked.connect (on_clicked);

            poll.begin ();
            arm (wanted_interval ());
        }

        ~UpdateIndicator () {
            if (poll_id != 0) Source.remove (poll_id);
        }

        private uint wanted_interval () {
            return state == "downloading" ? 1 : POLL_SECONDS;
        }

        private void arm (uint seconds) {
            if (poll_id != 0) Source.remove (poll_id);
            interval = seconds;
            poll_id = Timeout.add_seconds (seconds, on_tick);
        }

        private bool on_tick () {
            poll.begin ();
            return Source.CONTINUE;
        }

        private void update_interval () {
            uint wanted = wanted_interval ();
            if (wanted != interval) arm (wanted);
        }

        private async string? request (string method, string path) {
            try {
                var client = new SocketClient ();
                client.timeout = 2;
                var connection = yield client.connect_async (
                    new UnixSocketAddress (SOCKET), null
                );
                var request_text = method + " " + path
                    + " HTTP/1.0\r\nHost: localhost\r\n\r\n";
                size_t written;
                yield connection.output_stream.write_all_async (
                    request_text.data, Priority.DEFAULT, null, out written
                );
                var input = new DataInputStream (connection.input_stream);
                var body = new StringBuilder ();
                string? line;
                bool in_body = false;
                size_t length;
                while ((line = yield input.read_line_async (
                    Priority.DEFAULT, null, out length
                )) != null) {
                    if (in_body) {
                        if (body.len + line.length > 65536) return null;
                        body.append (line);
                    } else if (line.length == 0 || line == "\r") {
                        in_body = true;
                    }
                }
                return body.str;
            } catch (Error e) {
                return null;
            }
        }

        private async void poll () {
            if (polling) return;
            polling = true;
            var body = yield request ("GET", "/status");
            if (body == null) {
                polling = false;
                visible = false;
                return;
            }
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (body);
                var root = parser.get_root ();
                if (root == null
                    || root.get_node_type () != Json.NodeType.OBJECT) {
                    polling = false;
                    return;
                }
                var object = root.get_object ();
                state = object.get_string_member_with_default ("state", "idle");
                latest = object.get_string_member_with_default ("latest", "");
                percent = (int) object.get_int_member_with_default ("percent", 0);
            } catch (Error e) {
                polling = false;
                return;
            }
            polling = false;
            render ();
            update_interval ();
        }

        private void render () {
            switch (state) {
                case "available":
                    icon.icon_name = "software-update-available-symbolic";
                    set_tooltip_text (_("Update available: %s").printf (latest));
                    visible = true;
                    break;
                case "downloading":
                    icon.icon_name = "folder-download-symbolic";
                    set_tooltip_text (_("Downloading update: %d%%").printf (percent));
                    visible = true;
                    break;
                case "ready":
                    icon.icon_name = "emblem-ok-symbolic";
                    set_tooltip_text (_("Update ready: restart to apply %s").printf (latest));
                    visible = true;
                    break;
                case "error":
                    icon.icon_name = "dialog-error-symbolic";
                    set_tooltip_text (_("Update failed"));
                    visible = true;
                    break;
                default:
                    visible = false;
                    break;
            }
        }

        private void on_clicked () {
            switch (state) {
                case "available":
                    start_download.begin ();
                    break;
                case "ready":
                    confirm_restart ();
                    break;
                default:
                    break;
            }
        }

        private async void start_download () {
            state = "downloading";
            percent = 0;
            render ();
            update_interval ();
            yield request ("POST", "/download");
            yield poll ();
        }

        private void confirm_restart () {
            var dialog = new Gtk.AlertDialog (_("Restart to apply %s?").printf (latest));
            dialog.set_detail (_("The update was downloaded and verified. Your session will close."));
            dialog.set_buttons ({ _("Later"), _("Restart now") });
            dialog.set_cancel_button (0);
            dialog.set_default_button (1);
            dialog.choose.begin ((Gtk.Window?) get_root (), null, (obj, result) => {
                try {
                    if (dialog.choose.end (result) == 1) {
                        request.begin ("POST", "/reboot");
                    }
                } catch (Error e) {
                }
            });
        }
    }
}
