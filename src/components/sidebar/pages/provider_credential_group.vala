using Gtk;

namespace Singularity.Shell {
    // Shared credential UI: providers choose an email or a secret-key row
    // and handle submission without putting credentials in command arguments.
    public class ProviderCredentialGroup : Adw.PreferencesGroup {
        public signal void submitted(string value);
        private Adw.EntryRow entry;
        private Button submit;
        private Adw.ActionRow state;

        public ProviderCredentialGroup(string provider, string prompt, bool secret, string explanation) {
            title = provider;
            description = explanation;
            entry = secret ? new Adw.PasswordEntryRow() : new Adw.EntryRow();
            entry.title = prompt;
            submit = new Button.with_label(_("Submit"));
            submit.valign = Align.CENTER;
            submit.clicked.connect(() => {
                string value = entry.text.strip();
                if (value != "") submitted(value);
            });
            entry.add_suffix(submit);
            add(entry);
            state = new Adw.ActionRow();
            state.use_markup = false;
            state.visible = false;
            add(state);
        }

        public void set_state(string message, bool can_submit) {
            state.title = message;
            state.visible = message != "";
            entry.sensitive = can_submit;
            submit.sensitive = can_submit;
            if (!can_submit) entry.text = "";
        }
    }
}
