using Gtk;
using Singularity.Widgets;
using Singularity.Calendar;
using Goa;

namespace Singularity.SidebarPages {

    public class AccountsPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup calendars_group;

        public AccountsPage(SettingsView view) {
            base(_("Online Accounts"));
            this.view = view;
            back_clicked.connect(() => {
                view.go_home();
            });
            var local_group = new PreferencesGroup(_("Local Calendar"));
            var import_row = new ActionRow(_("Add Calendar from File"), _("Import events from .ics file"), "x-office-calendar-symbolic");
            var import_btn = new Button.with_label(_("Add"));
            import_btn.add_css_class("flat");
            import_btn.clicked.connect(() => {
                var app = (SingularityApp) GLib.Application.get_default();
                if (app.sidebar != null) {
                    app.sidebar.open_file_picker("Calendar Files", { "*.ics" }, (file) => {
                        import_calendar(file);
                    });
                }
            });
            import_row.add_suffix(import_btn);
            local_group.add_row(import_row);
            add_group(local_group);
            calendars_group = new PreferencesGroup(_("My Calendars"));
            refresh_list();
            add_group(calendars_group);
            var cloud_group = new PreferencesGroup(_("Online Accounts"));
            load_accounts.begin(cloud_group);
            var add_row = new ActionRow(_("Add Account"), _("Connect to Google, Nextcloud, etc."), "list-add-symbolic");
            var add_btn = new Button.with_label(_("Add"));
            add_btn.add_css_class("flat");
            add_btn.clicked.connect(() => {
                var page = new Singularity.SidebarPages.AddAccountPage(view);
                view.open_subpage(page, "add-account");
            });
            add_row.add_suffix(add_btn);
            cloud_group.add_row(add_row);
            add_group(cloud_group);
        }

    private void import_calendar(File file) {
            var path = file.get_path();
            if (path != null) {
                string filename = file.get_basename();
                string name = filename;
                if (name.has_suffix(".ics")) {
                    name = name.substring(0, name.length - 4);
                }
                string storage_name = name + ".json";
                string id = "local-" + name;
                var manager = CalendarManager.get_default();
                if (manager.get_provider(id) != null) {
                    warning("Calendar %s already exists", name);
                    return;
                }
                string color = "#3584e4";
                var provider = new LocalProvider(name, id, storage_name, color);
                provider.import_file.begin(path, (obj, res) => {
                    try {
                        provider.import_file.end(res);
                        manager.register_provider(provider);
                        refresh_list();
                    } catch (GLib.Error e) {
                        warning("Failed to import calendar: %s", e.message);
                    }
                });
            }
        }

        private async void load_accounts(PreferencesGroup group) {
            try {
                var client = yield new global::Goa.Client(null);
                var objects = client.get_accounts();
                foreach (var object in objects) {
                    var account = object.get_account();
                    var row = new ConfirmRow(account.presentation_identity, "This will remove the account from this device.", "avatar-default-symbolic");
                    row.confirmed.connect(() => {
                        account.call_remove.begin(null, (obj, res) => {
                            try {
                                account.call_remove.end(res);
                            } catch (GLib.Error e) {
                                warning("Failed to remove account: %s", e.message);
                            }
                        });
                    });
                    group.add_row(row);
                }
                client.account_added.connect((object) => {
                    var account = object.get_account();
                    var row = new ConfirmRow(account.presentation_identity, "This will remove the account from this device.", "avatar-default-symbolic");
                    row.confirmed.connect(() => {
                        account.call_remove.begin(null, (obj, res) => {
                            try {
                                account.call_remove.end(res);
                            } catch (GLib.Error e) {
                                warning("Failed to remove account: %s", e.message);
                            }
                        });
                    });
                    group.add_row(row);
                });
                client.account_removed.connect((object) => {
                    load_accounts.begin(group);
                });
            } catch (GLib.Error e) {
                warning("Failed to load GOA accounts: %s", e.message);
            }
        }

        private void refresh_list() {
            calendars_group.clear();
            var manager = CalendarManager.get_default();
            var providers = manager.get_providers();
            foreach (var provider in providers) {
                var row = new SwitchRow(provider.name, provider.id, provider.is_visible);
                row.switch_btn.notify["active"].connect(() => {
                    provider.is_visible = row.active;
                });
                if (provider.id != "local-provider" && provider.id.has_prefix("local-")) {
                    var del_btn = new Button.from_icon_name("user-trash-symbolic");
                    del_btn.add_css_class("flat");
                    del_btn.add_css_class("destructive-action");
                    del_btn.clicked.connect(() => {
                        row.confirmation_requested(_("Remove"), _("Cancel"),
                            ConfirmationSuggestedAction.CANCEL);
                    });
                    row.confirmed.connect(() => {
                        if (provider is LocalProvider) {
                            ((LocalProvider)provider).delete();
                        }
                        manager.unregister_provider(provider.id);
                        refresh_list();
                    });
                    row.add_suffix(del_btn);
                }
                calendars_group.add_row(row);
            }
        }
    }
}
