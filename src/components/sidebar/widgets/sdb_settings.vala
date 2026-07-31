using Gtk;
using Singularity.Widgets;

namespace Singularity {

    [DBus (name = "io.github.singularityos_lab.ush.Broker1")]
    interface SdbBroker : Object {
        public abstract async void sdb_status (out bool available, out bool active,
            out string message) throws GLib.Error;
        public abstract async void set_sdb_enabled (bool enabled, out bool ok,
            out bool active, out string message) throws GLib.Error;
    }

    public class SdbSettings : Box {
        private PreferencesGroup bridge_group;
        private SwitchRow bridge_switch;
        private Label error_label;
        private ActionRow device_row;
        private Label device_fingerprint;
        private ActionRow pair_row;
        private PreferencesGroup pairing_group;
        private Label pair_code;
        private Label pair_expiry;
        private Label pair_fingerprint;
        private Label pair_fingerprint_caption;
        private Label pair_attempts;
        private Label pair_host;
        private PreferencesGroup hosts_group;
        private string hosts_signature = "";
        private bool switch_guard = false;
        private bool refreshing = false;
        private bool bridge_refreshing = false;
        private bool applying_enabled = false;
        private uint timer_id = 0;

        public SdbSettings () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            build_ui ();
            map.connect (() => {
                refresh_state.begin ();
                start_timer ();
            });
            unmap.connect (stop_timer);
        }

        protected override void dispose () {
            stop_timer ();
            base.dispose ();
        }

        private void append_group (Widget group) {
            group.margin_top = 12;
            append (group);
        }

        private void build_ui () {
            bridge_group = new PreferencesGroup (_("Debug bridge"));
            bridge_group.description = _(
                "Lets a paired development machine connect over the network for a shell, file transfer and logs. Privileged actions still ask for approval."
            );

            bridge_switch = new SwitchRow (
                _("Debug bridge"),
                _("A host must pair with the code shown here before it can connect")
            );
            bridge_switch.switch_btn.notify["active"].connect (on_toggled);
            bridge_group.add_row (bridge_switch);
            append_group (bridge_group);

            error_label = new Label ("");
            error_label.add_css_class ("error");
            error_label.wrap = true;
            error_label.visible = false;
            error_label.margin_start = 16;
            error_label.margin_end = 16;
            error_label.halign = Gtk.Align.START;
            append (error_label);

            device_row = new ActionRow (
                _("This device fingerprint"), null, "fingerprint-symbolic"
            );
            device_fingerprint = new Label ("");
            device_fingerprint.selectable = true;
            device_fingerprint.halign = Gtk.Align.END;
            device_fingerprint.hexpand = true;
            device_fingerprint.wrap = true;
            device_fingerprint.wrap_mode = Pango.WrapMode.WORD_CHAR;
            device_fingerprint.justify = Justification.RIGHT;
            device_fingerprint.add_css_class ("monospace");
            device_fingerprint.add_css_class ("caption");
            device_row.add_suffix (device_fingerprint);
            device_row.visible = false;
            bridge_group.add_row (device_row);

            pair_row = new ActionRow (
                _("Pair a new host"),
                _("Show a code for a development machine to type"),
                "list-add-symbolic"
            );
            var pair_button = new Button.with_label (_("Start"));
            pair_button.valign = Gtk.Align.CENTER;
            pair_button.add_css_class ("pill");
            pair_button.clicked.connect (() => {
                start_pairing.begin ();
            });
            pair_row.add_suffix (pair_button);
            pair_row.visible = false;
            bridge_group.add_row (pair_row);

            pairing_group = new PreferencesGroup (_("Pairing request"));
            pairing_group.description = _(
                "Type this code on the host. Check that the host key fingerprint shown here matches before entering it."
            );
            pairing_group.visible = false;

            pair_host = new Label ("");
            pair_host.wrap = true;
            pair_host.halign = Gtk.Align.CENTER;
            pair_host.add_css_class ("dim-label");
            pair_host.visible = false;

            pair_code = new Label ("");
            pair_code.halign = Gtk.Align.CENTER;
            pair_code.selectable = true;
            pair_code.add_css_class ("large-title");
            pair_code.add_css_class ("monospace");

            pair_expiry = new Label ("");
            pair_expiry.halign = Gtk.Align.CENTER;
            pair_expiry.wrap = true;
            pair_expiry.add_css_class ("caption");
            pair_expiry.add_css_class ("dim-label");

            pair_fingerprint_caption = new Label (_("Host key fingerprint"));
            pair_fingerprint_caption.halign = Gtk.Align.CENTER;
            pair_fingerprint_caption.add_css_class ("heading");

            pair_fingerprint = new Label ("");
            pair_fingerprint.halign = Gtk.Align.CENTER;
            pair_fingerprint.justify = Justification.CENTER;
            pair_fingerprint.wrap = true;
            pair_fingerprint.wrap_mode = Pango.WrapMode.WORD_CHAR;
            pair_fingerprint.selectable = true;
            pair_fingerprint.add_css_class ("monospace");
            pair_fingerprint.add_css_class ("caption");

            pair_attempts = new Label ("");
            pair_attempts.halign = Gtk.Align.CENTER;
            pair_attempts.wrap = true;
            pair_attempts.add_css_class ("caption");
            pair_attempts.add_css_class ("error");
            pair_attempts.visible = false;

            var cancel_button = new Button.with_label (_("Cancel pairing"));
            cancel_button.halign = Gtk.Align.CENTER;
            cancel_button.add_css_class ("pill");
            cancel_button.clicked.connect (() => {
                cancel_pairing.begin ();
            });

            var pair_box = new Box (Orientation.VERTICAL, 8);
            pair_box.margin_start = 16;
            pair_box.margin_end = 16;
            pair_box.margin_top = 12;
            pair_box.margin_bottom = 12;
            pair_box.append (pair_host);
            pair_box.append (pair_code);
            pair_box.append (pair_expiry);
            pair_box.append (pair_fingerprint_caption);
            pair_box.append (pair_fingerprint);
            pair_box.append (pair_attempts);
            pair_box.append (cancel_button);
            pairing_group.add_row (pair_box);
            append_group (pairing_group);

            hosts_group = new PreferencesGroup (_("Paired hosts"));
            hosts_group.description = _(
                "Hosts allowed to connect to this device. A revoked host must pair again."
            );
            hosts_group.visible = false;
            append_group (hosts_group);
        }

        private void on_toggled () {
            if (switch_guard || applying_enabled) return;
            apply_enabled.begin (bridge_switch.switch_btn.active);
        }

        private async void apply_enabled (bool wanted) {
            if (applying_enabled) return;
            applying_enabled = true;
            bridge_switch.sensitive = false;
            bool ok;
            bool active;
            string message;
            bool answered = yield SdbService.set_enabled (
                wanted, out ok, out active, out message
            );

            if (!answered) {
                show_error (
                    wanted
                        ? _("The debug bridge could not be turned on. %s").printf (message)
                        : _("The debug bridge could not be turned off and may still be listening. %s").printf (message)
                );
                applying_enabled = false;
                yield refresh_state ();
                return;
            }

            bridge_switch.sensitive = true;
            set_switch (active);
            if (ok && active == wanted) {
                show_error (null);
            } else if (wanted) {
                show_error (
                    _("The debug bridge could not be turned on. %s").printf (message)
                );
            } else {
                show_error (
                    _("The debug bridge could not be turned off and is still listening. %s").printf (message)
                );
            }

            if (active) refresh_bridge.begin ();
            else hide_bridge_details ();
            applying_enabled = false;
        }

        private async void refresh_state () {
            if (refreshing) return;
            refreshing = true;

            bool available;
            bool active;
            string message;
            bool answered = yield SdbService.status (
                out available, out active, out message
            );
            refreshing = false;
            if (applying_enabled) return;

            if (!answered) {
                bridge_switch.sensitive = false;
                hide_bridge_details ();
                show_error (
                    _("The debug bridge state could not be confirmed. %s").printf (message)
                );
                return;
            }
            if (!available) {
                set_switch (active);
                bridge_switch.sensitive = active;
                hide_bridge_details ();
                show_error (
                    message != ""
                        ? message
                        : _("The debug bridge is not available on this device.")
                );
                return;
            }

            bridge_switch.sensitive = true;
            set_switch (active);
            show_error (null);
            if (active) refresh_bridge.begin ();
            else hide_bridge_details ();
        }

        private void hide_bridge_details () {
            device_row.visible = false;
            pair_row.visible = false;
            pairing_group.visible = false;
            hosts_group.visible = false;
            hosts_signature = "";
        }

        private async void start_pairing () {
            string message;
            if (yield SdbAgent.pairing_start (out message)) {
                show_error (null);
                refresh_bridge.begin ();
            } else {
                show_error (
                    _("Pairing could not be started. %s").printf (message)
                );
            }
        }

        private async void cancel_pairing () {
            string message;
            if (yield SdbAgent.pairing_cancel (out message)) {
                show_error (null);
            } else {
                show_error (
                    _("Pairing could not be cancelled. %s").printf (message)
                );
            }
            refresh_bridge.begin ();
        }

        private async void refresh_bridge () {
            if (bridge_refreshing) return;
            bridge_refreshing = true;

            var device = yield SdbAgent.device ();
            if (device != null) {
                device_fingerprint.label = device.display ();
                device_row.visible = true;
            } else {
                device_row.visible = false;
            }

            var pairing = yield SdbAgent.pairing_state ();
            if (pairing == null) {
                pair_row.visible = false;
                pairing_group.visible = false;
                show_error (
                    _("The debug bridge is running, but its pairing state could not be read.")
                );
            } else if (pairing.locked_out ()) {
                pair_row.visible = false;
                pairing_group.visible = false;
                show_error (
                    _("Too many wrong codes were entered. Pairing is blocked until %s.")
                        .printf (pairing.locked_until_text ())
                );
            } else if (pairing.active && pairing.code != "") {
                pair_row.visible = false;
                pair_code.label = pairing.code;
                pair_expiry.label = pairing.expires_text ();

                bool has_host = pairing.pending_fingerprint_display != ""
                    || pairing.pending_fingerprint != "";
                pair_fingerprint_caption.visible = has_host;
                pair_fingerprint.visible = has_host;
                if (has_host) {
                    pair_fingerprint.label = pairing.fingerprint_display ();
                }

                if (pairing.pending_label != "") {
                    pair_host.label = _("Requested by %s").printf (
                        pairing.pending_label
                    );
                    pair_host.visible = true;
                } else if (has_host) {
                    pair_host.visible = false;
                } else {
                    pair_host.label = _(
                        "Waiting for a host. Its fingerprint appears here before the code is accepted."
                    );
                    pair_host.visible = true;
                }

                if (pairing.attempts > 0) {
                    pair_attempts.label = ngettext (
                        "%d wrong code has been tried.",
                        "%d wrong codes have been tried.",
                        pairing.attempts
                    ).printf (pairing.attempts);
                    pair_attempts.visible = true;
                } else {
                    pair_attempts.visible = false;
                }
                pairing_group.visible = true;
            } else {
                pair_row.visible = true;
                pairing_group.visible = false;
            }

            yield refresh_hosts ();
            bridge_refreshing = false;
        }

        private async void refresh_hosts () {
            var hosts = yield SdbAgent.hosts ();
            if (hosts == null) {
                hosts_signature = "";
                hosts_group.clear ();
                hosts_group.add_row (new ActionRow (
                    _("Paired hosts"),
                    _("The list could not be read. No host has been revoked."),
                    "dialog-warning-symbolic"
                ));
                hosts_group.visible = true;
                return;
            }

            var signature = new StringBuilder ();
            foreach (var host in hosts) {
                signature.append (host.label);
                signature.append ("|");
                signature.append (host.fingerprint);
                signature.append ("|");
                signature.append (host.paired_at);
                signature.append ("|");
                signature.append (host.last_used);
                signature.append ("\n");
            }
            if (signature.str == hosts_signature) {
                hosts_group.visible = true;
                return;
            }
            hosts_signature = signature.str;

            hosts_group.clear ();
            if (hosts.size == 0) {
                hosts_group.add_row (new ActionRow (
                    _("No paired hosts"),
                    _("No development machine can connect to this device yet."),
                    "computer-symbolic"
                ));
                hosts_group.visible = true;
                return;
            }

            foreach (var item in hosts) {
                var host = item;
                var row = new ConfirmRow (
                    host.label,
                    _("Last used %s. Fingerprint %s").printf (
                        host.last_used_text (), host.fingerprint_display ()
                    ),
                    "computer-symbolic"
                );
                row.confirm_label = _("Revoke");
                row.confirmed.connect (() => {
                    revoke_host.begin (host);
                });
                hosts_group.add_row (row);
            }
            hosts_group.visible = true;
        }

        private async void revoke_host (SdbPairedHost host) {
            string message;
            if (yield SdbAgent.revoke (host.label, out message)) {
                show_error (null);
                hosts_signature = "";
                refresh_hosts.begin ();
            } else {
                show_error (
                    _("%s was not revoked and can still connect. %s")
                        .printf (host.label, message)
                );
            }
        }

        private void show_error (string? message) {
            error_label.label = message ?? "";
            error_label.visible = message != null;
        }

        private void set_switch (bool active) {
            switch_guard = true;
            bridge_switch.switch_btn.active = active;
            switch_guard = false;
        }

        private void start_timer () {
            if (timer_id != 0) return;
            timer_id = Timeout.add_seconds (2, () => {
                refresh_state.begin ();
                return Source.CONTINUE;
            });
        }

        private void stop_timer () {
            if (timer_id == 0) return;
            Source.remove (timer_id);
            timer_id = 0;
        }
    }

    class SdbDevice {
        public string fingerprint;
        public string fingerprint_display;

        public string display () {
            return fingerprint_display != ""
                ? fingerprint_display
                : SdbText.format_fingerprint (fingerprint);
        }
    }

    class SdbPairingState {
        public bool active;
        public string code;
        public string expires_at;
        public string pending_fingerprint;
        public string pending_fingerprint_display;
        public string pending_label;
        public int attempts;
        public string locked_until;

        public string fingerprint_display () {
            return pending_fingerprint_display != ""
                ? pending_fingerprint_display
                : SdbText.format_fingerprint (pending_fingerprint);
        }

        public bool locked_out () {
            var until = SdbAgent.parse_time (locked_until);
            return until != null && until.compare (new DateTime.now_utc ()) > 0;
        }

        public string locked_until_text () {
            var until = SdbAgent.parse_time (locked_until);
            return until == null
                ? ""
                : until.to_local ().format ("%H:%M").strip ();
        }

        public string expires_text () {
            var expiry = SdbAgent.parse_time (expires_at);
            if (expiry == null) return "";
            int64 left = expiry.difference (new DateTime.now_utc ())
                / TimeSpan.SECOND;
            if (left <= 0) return _("This code has expired. Start pairing again.");
            if (left < 60) {
                return ngettext (
                    "Expires in %d second.",
                    "Expires in %d seconds.",
                    (ulong) left
                ).printf ((int) left);
            }
            int minutes = (int) ((left + 59) / 60);
            return ngettext (
                "Expires in %d minute.",
                "Expires in %d minutes.",
                (ulong) minutes
            ).printf (minutes);
        }
    }

    class SdbPairedHost {
        public string label;
        public string fingerprint;
        public string fingerprint_display_raw;
        public string paired_at;
        public string last_used;

        public string fingerprint_display () {
            return fingerprint_display_raw != ""
                ? fingerprint_display_raw
                : SdbText.format_fingerprint (fingerprint);
        }

        public string last_used_text () {
            var time = SdbAgent.parse_time (last_used);
            return time == null
                ? _("never")
                : time.to_local ().format ("%e %b %Y, %H:%M").strip ();
        }
    }

    class SdbText {
        public static string format_fingerprint (string? fingerprint) {
            if (fingerprint == null || fingerprint.strip () == "") {
                return _("not provided");
            }

            string text = fingerprint.strip ();
            int colons = 0;
            for (int i = 0; i < text.length; i++) {
                if (text[i] == ':') colons++;
            }

            string prefix = "";
            int colon = text.index_of (":");
            if (colons == 1 && colon > 0) {
                prefix = text.substring (0, colon + 1) + " ";
                text = text.substring (colon + 1);
            }
            if (text.index_of (" ") >= 0) return prefix + text;

            var grouped = new StringBuilder ();
            int count = 0;
            for (int i = 0; i < text.length; i++) {
                if (text[i] == ':') continue;
                if (count > 0 && count % 4 == 0) grouped.append_c (' ');
                grouped.append_c (text[i]);
                count++;
            }
            return prefix + grouped.str;
        }
    }

    class SdbService {
        private const string BUS_NAME =
            "io.github.singularityos_lab.ush.Broker";
        private const string OBJECT_PATH =
            "/io/github/singularityos_lab/ush/Broker";

        public static async bool status (
            out bool available, out bool active, out string message
        ) {
            available = false;
            active = false;
            message = "";
            try {
                SdbBroker broker = yield Bus.get_proxy (
                    BusType.SESSION, BUS_NAME, OBJECT_PATH
                );
                yield broker.sdb_status (
                    out available, out active, out message
                );
                return true;
            } catch (GLib.Error e) {
                warning ("SDB status failed: %s", e.message);
                message = _("The security service is not available.");
                return false;
            }
        }

        public static async bool set_enabled (
            bool enabled, out bool ok, out bool active, out string message
        ) {
            ok = false;
            active = false;
            message = "";
            try {
                SdbBroker broker = yield Bus.get_proxy (
                    BusType.SESSION, BUS_NAME, OBJECT_PATH
                );
                yield broker.set_sdb_enabled (
                    enabled, out ok, out active, out message
                );
                if (!ok && message == "") {
                    message = _("The request was refused.");
                }
                return true;
            } catch (GLib.Error e) {
                warning ("SDB state change failed: %s", e.message);
                message = _("The security service is not available.");
                return false;
            }
        }
    }

    class SdbAgent {
        private const string SOCKET_PATH = "/run/sinty-sdb.sock";
        private const int MAX_RESPONSE = 1024 * 1024;

        public static DateTime? parse_time (string? value) {
            if (value == null || value.strip () == "") return null;
            var time = new DateTime.from_iso8601 (value, null);
            if (time == null || time.get_year () <= 1) return null;
            return time.to_utc ();
        }

        private static async string? request (
            string method, string path, string? body, out int status
        ) {
            status = 0;
            try {
                var client = new SocketClient ();
                client.timeout = 2;
                var connection = yield client.connect_async (
                    new UnixSocketAddress (SOCKET_PATH), null
                );

                var request = new StringBuilder ();
                request.append ("%s %s HTTP/1.1\r\n".printf (method, path));
                request.append ("Host: localhost\r\n");
                request.append ("Connection: close\r\n");
                if (body != null) {
                    request.append ("Content-Type: application/json\r\n");
                    request.append (
                        "Content-Length: %d\r\n".printf (body.length)
                    );
                }
                request.append ("\r\n");
                if (body != null) request.append (body);
                size_t written;
                yield connection.output_stream.write_all_async (
                    request.str.data, Priority.DEFAULT, null, out written
                );

                var raw = new ByteArray ();
                var buffer = new uint8[4096];
                while (true) {
                    ssize_t received = yield connection.input_stream.read_async (
                        buffer, Priority.DEFAULT, null
                    );
                    if (received <= 0) break;
                    if (raw.len + received > MAX_RESPONSE) {
                        return null;
                    }
                    raw.append (buffer[0:(int) received]);
                }
                if (raw.len == 0) return null;
                raw.append ({ 0 });

                string response = (string) raw.data;
                int separator = response.index_of ("\r\n\r\n");
                if (separator < 0) return null;
                string head = response.substring (0, separator);
                int line_end = head.index_of ("\r\n");
                string status_line = line_end < 0
                    ? head
                    : head.substring (0, line_end);
                string[] parts = status_line.split (" ");
                if (parts.length >= 2) status = int.parse (parts[1]);
                return response.substring (separator + 4);
            } catch (GLib.Error e) {
                warning ("SDB request %s %s failed: %s", method, path, e.message);
                return null;
            }
        }

        private static Json.Object? parse_object (string? body) {
            if (body == null) return null;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (body);
                var root = parser.get_root ();
                if (root == null
                    || root.get_node_type () != Json.NodeType.OBJECT) {
                    return null;
                }
                return root.get_object ();
            } catch (GLib.Error e) {
                return null;
            }
        }

        private static string member_string (Json.Object object, string name) {
            if (!object.has_member (name)) return "";
            var node = object.get_member (name);
            if (node == null || node.get_node_type () != Json.NodeType.VALUE) {
                return "";
            }
            return node.get_string () ?? "";
        }

        private static bool member_bool (Json.Object object, string name) {
            if (!object.has_member (name)) return false;
            var node = object.get_member (name);
            return node != null
                && node.get_node_type () == Json.NodeType.VALUE
                && node.get_boolean ();
        }

        private static string failure_message (Json.Object? object) {
            if (object == null) {
                return _("The debug bridge sent an unreadable response.");
            }
            string message = member_string (object, "error");
            if (message == "") message = member_string (object, "message");
            return message != ""
                ? message
                : _("The debug bridge refused the request.");
        }

        public static async SdbDevice? device () {
            int status;
            var object = parse_object (
                yield request ("GET", "/device", null, out status)
            );
            if (status != 200 || object == null
                || !object.has_member ("fingerprint")) {
                return null;
            }
            var device = new SdbDevice ();
            device.fingerprint = member_string (object, "fingerprint");
            device.fingerprint_display =
                member_string (object, "fingerprint_display");
            return device.fingerprint == ""
                    && device.fingerprint_display == ""
                ? null
                : device;
        }

        public static async SdbPairingState? pairing_state () {
            int status;
            var object = parse_object (
                yield request ("GET", "/pairing/state", null, out status)
            );
            if (status != 200 || object == null
                || !object.has_member ("active")) {
                return null;
            }

            var state = new SdbPairingState ();
            state.active = member_bool (object, "active");
            state.code = member_string (object, "code");
            state.expires_at = member_string (object, "expires_at");
            state.pending_fingerprint =
                member_string (object, "pending_fingerprint");
            state.pending_fingerprint_display =
                member_string (object, "pending_fingerprint_display");
            state.pending_label = member_string (object, "pending_label");
            state.locked_until = member_string (object, "locked_until");
            state.attempts = object.has_member ("attempts")
                ? (int) object.get_int_member ("attempts")
                : 0;
            return state;
        }

        public static async bool pairing_start (out string message) {
            return yield action (
                "POST", "/pairing/start", null, out message
            );
        }

        public static async bool pairing_cancel (out string message) {
            return yield action (
                "POST", "/pairing/cancel", null, out message
            );
        }

        public static async Gee.ArrayList<SdbPairedHost>? hosts () {
            int status;
            var object = parse_object (
                yield request ("GET", "/hosts", null, out status)
            );
            if (status != 200 || object == null
                || !object.has_member ("hosts")) {
                return null;
            }
            var node = object.get_member ("hosts");
            if (node == null || node.get_node_type () != Json.NodeType.ARRAY) {
                return null;
            }

            var hosts = new Gee.ArrayList<SdbPairedHost> ();
            var array = node.get_array ();
            for (uint i = 0; i < array.get_length (); i++) {
                var item = array.get_element (i);
                if (item == null
                    || item.get_node_type () != Json.NodeType.OBJECT) {
                    return null;
                }
                var entry = item.get_object ();
                string label = member_string (entry, "label");
                if (label == "") return null;

                var host = new SdbPairedHost ();
                host.label = label;
                host.fingerprint = member_string (entry, "fingerprint");
                host.fingerprint_display_raw =
                    member_string (entry, "fingerprint_display");
                host.paired_at = member_string (entry, "paired_at");
                host.last_used = member_string (entry, "last_used");
                hosts.add (host);
            }
            return hosts;
        }

        public static async bool revoke (string label, out string message) {
            var node = new Json.Node (Json.NodeType.VALUE);
            node.set_string (label);
            return yield action (
                "POST",
                "/hosts/revoke",
                "{\"label\":%s}".printf (Json.to_string (node, false)),
                out message
            );
        }

        private static async bool action (
            string method, string path, string? body, out string message
        ) {
            int status;
            var object = parse_object (
                yield request (method, path, body, out status)
            );
            bool ok = status == 200
                && object != null
                && member_bool (object, "ok");
            message = ok ? "" : failure_message (object);
            return ok;
        }
    }
}
