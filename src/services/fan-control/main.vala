using GLib;

namespace Singularity {

    [DBus (name = "dev.sinty.FanControl1")]
    public class FanControlService : Object {
        private const string ACTION_ID = "dev.sinty.fan-control.configure";
        private FanController controller;

        public signal void channels_changed();

        public FanControlService(FanController controller) {
            this.controller = controller;
            controller.changed.connect(() => channels_changed());
        }

        public HashTable<string, Variant>[] get_channels() throws Error {
            controller.touch();
            return controller.describe();
        }

        public async void set_curve(string id, int[] temps, int[] percents, BusName sender) throws Error {
            yield authorize(sender);
            controller.apply(id, temps, percents);
        }

        public async void reset_firmware(string id, BusName sender) throws Error {
            yield authorize(sender);
            controller.reset(id);
        }

        private async void authorize(string sender) throws Error {
            controller.touch();
            var authority = yield Polkit.Authority.get_async(null);
            var result = yield authority.check_authorization(
                new Polkit.SystemBusName(sender), ACTION_ID, null,
                Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION, null);
            if (!result.get_is_authorized()) {
                throw new FanControlError.NOT_AUTHORIZED("Changing the fan curve was not authorized");
            }
        }
    }

    private const string STATE_PATH = "/run/singularity-fan-control/manual.conf";
    private const string CONFIG_DIR = "/var/lib/singularity-fan-control";
    private const int IDLE_EXIT_SECONDS = 120;

    private void sd_notify(string message) {
        string? path = Environment.get_variable("NOTIFY_SOCKET");
        if (path == null || path == "") return;
        try {
            var socket = new Socket(SocketFamily.UNIX, SocketType.DATAGRAM, SocketProtocol.DEFAULT);
            SocketAddress address = path[0] == '@'
                ? new UnixSocketAddress.with_type(path.substring(1), -1, UnixSocketAddressType.ABSTRACT)
                : new UnixSocketAddress(path);
            socket.send_to(address, message.data);
        } catch (Error e) {
            warning("fan control: sd_notify failed: %s", e.message);
        }
    }

    private void watch_sleep(DBusConnection conn, FanController controller) {
        conn.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager",
            "PrepareForSleep", "/org/freedesktop/login1", null, DBusSignalFlags.NONE,
            (c, sender, path, iface, name, parameters) => {
                bool sleeping = false;
                parameters.get("(b)", out sleeping);
                if (sleeping) {
                    controller.release_all();
                } else {
                    controller.resume();
                }
            });
    }

    public int main(string[] args) {
        if (args.length > 1 && args[1] == "--restore") {
            FanController.restore_from_state(STATE_PATH);
            return 0;
        }

        var loop = new MainLoop();
        var controller = new FanController("", CONFIG_DIR, STATE_PATH);
        FanController.restore_from_state(STATE_PATH);
        controller.start();

        Bus.own_name(BusType.SYSTEM, "dev.sinty.FanControl", BusNameOwnerFlags.NONE,
            (conn) => {
                try {
                    conn.register_object("/dev/sinty/FanControl", new FanControlService(controller));
                } catch (IOError e) {
                    warning("fan control: cannot export the service: %s", e.message);
                    loop.quit();
                }
                watch_sleep(conn, controller);
            },
            null,
            () => loop.quit());

        Unix.signal_add(ProcessSignal.TERM, () => {
            loop.quit();
            return Source.REMOVE;
        });
        Unix.signal_add(ProcessSignal.INT, () => {
            loop.quit();
            return Source.REMOVE;
        });

        string? watchdog = Environment.get_variable("WATCHDOG_USEC");
        uint64 watchdog_usec = 0;
        if (watchdog != null && uint64.try_parse(watchdog, out watchdog_usec) && watchdog_usec > 0) {
            Timeout.add((uint) (watchdog_usec / 2000), () => {
                sd_notify("WATCHDOG=1");
                return Source.CONTINUE;
            });
        }

        Timeout.add_seconds(30, () => {
            if (!controller.has_software_curves() && controller.idle_seconds() >= IDLE_EXIT_SECONDS) {
                loop.quit();
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });

        loop.run();
        controller.release_all();
        return 0;
    }
}
