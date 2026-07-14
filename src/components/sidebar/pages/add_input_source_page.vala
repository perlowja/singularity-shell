using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AddInputSourcePage : SettingsPage {
        public signal void source_selected(string id, string name);
        private List<InputSourceInfo> all_sources;
        private Singularity.Widgets.SearchEntry search_entry;
        private PreferencesGroup list_group;
        private class InputSourceInfo {
            public string id;
            public string name;
            public string description;

            public InputSourceInfo(string id, string name, string description) {
                this.id = id;
                this.name = name;
                this.description = description;
            }
        }

        public AddInputSourcePage(SettingsView view) {
            base(_("Add Input Source"));
            back_clicked.connect(() => {
                view.navigate_to("keyboard");
            });
            all_sources = new List<InputSourceInfo>();
            search_entry = new Singularity.Widgets.SearchEntry();
            search_entry.placeholder_text = _("Search languages...");
            search_entry.search_changed.connect(filter_list);
            add_widget(search_entry);
            list_group = new PreferencesGroup(_("Available Layouts"));
            add_group(list_group);
            Idle.add(() => {
                load_sources();
                return false;
            });
        }

        private void load_sources() {
            var srcs = InputSourceUtil.list();
            foreach (var s in srcs) {
                all_sources.append(new InputSourceInfo(s.id, s.name, s.description));
            }
            inputsrc_dbg("load_sources: list()=%u all_sources=%u".printf(srcs.length, all_sources.length()));
            populate_list();
        }

        private void populate_list() {
            filter_list(search_entry);
        }

        private void filter_list(Singularity.Widgets.SearchEntry entry) {
            list_group.clear();
            string query = entry.text.down();
            int count = 0;
            foreach (var source in all_sources) {
                if (query == "" || source.name.down().contains(query) || source.description.down().contains(query)) {
                    var row = new ActionRow(source.name, source.description);
                    var btn = new Button.from_icon_name("list-add-symbolic");
                    btn.add_css_class("circular-button");
                    btn.valign = Align.CENTER;
                    btn.clicked.connect(() => {
                        source_selected(source.id, source.name);
                    });
                    row.add_suffix(btn);
                    row.activatable = true;
                    var gesture = new GestureClick();
                    gesture.released.connect(() => {
                        source_selected(source.id, source.name);
                    });
                    row.add_controller(gesture);
                    list_group.add_row(row);
                    count++;
                    if (count > 50) break;
                }
            }
            inputsrc_dbg("filter_list: query='%s' all=%u rows=%d".printf(query, all_sources.length(), count));
        }

        private void inputsrc_dbg(string msg) {
            string dir = Path.build_filename(Environment.get_user_state_dir(), "singularity");
            DirUtils.create_with_parents(dir, 0755);
            var f = FileStream.open(Path.build_filename(dir, "inputsrc.log"), "a");
            if (f != null) f.printf("%s\n", msg);
        }
    }
}
