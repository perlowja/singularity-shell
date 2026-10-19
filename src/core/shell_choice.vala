namespace Singularity.Shell {

    [DBus (name = "dev.sinty.Shell.Choice")]
    public class ShellChoiceService : Object {
        private weak SingularityApp app;

        public ShellChoiceService(SingularityApp app) {
            this.app = app;
        }

        public async bool show_choice(string title, string body, string allow_label, string block_label) throws IOError {
            return yield app.show_choice(title, body, allow_label, block_label);
        }
    }
}
