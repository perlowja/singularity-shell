using Gtk;
using Gee;
using Singularity.Widgets;

namespace Singularity.Shell {
    // Presentation only: the installed helper owns all OCS and import policy.
    public class WallpaperOcsBrowser : Gtk.Window {
        public signal void imported();
        public signal void dismissed();
        private const string HELPER = "/usr/local/bin/ncz-wallpaper-ocs";
        // Bing lives behind its own helper because its commands and JSON
        // shapes are different (markets -> TSV, list -> bare array, no
        // schema/items wrapper). Calling it is the same SubprocessLauncher
        // shape as HELPER; only the argv and the parsers in WallpaperBing
        // differ. There is NO copy/import path for Bing -- it is already a
        // persistent Wallpaper Source the moment it is archived, so the
        // per-item action here is PIN (which protects it from retention
        // pruning), not import.
        private const string BING_HELPER = "/usr/local/bin/ncz-wallpaper-bing";
        // The synthetic provider id used by the SelectionRow, the worker
        // branching, and the card layout. Same value as WallpaperBing.PROVIDER_ID
        // in core/ -- duplicated here so the browser can branch on it
        // without pulling in a core class field reference at the call site.
        private const string BING_PROVIDER_ID = "bing";
        // Bounded crawl: enough parallelism that a provider with many usable
        // categories fills the grid quickly, but small enough that a single
        // provider cannot fork dozens of OCS processes against the helper at
        // once. Empirically a provider exposes on the order of one to a few
        // dozen usable categories; 4 leaves headroom on each without spiking
        // the helper or the UI thread.
        private const int CRAWL_WORKERS = 4;
        // Hard cap on the total wallpapers merged across every usable category
        // for one provider. One page per category at ~50 items/page across
        // ~30 usable categories lands well under 1500 in practice; the cap is
        // a safety belt against future providers with very large per-category
        // pages or an order of magnitude more usable categories.
        private const int CRAWL_ITEM_CAP = 1500;
        // Per-category subprocess timeout, matches the previous single-call
        // bound so a slow category can't drag a worker beyond the overall
        // window the user is willing to wait.
        private const int CRAWL_CATEGORY_TIMEOUT = 60;
        private string[] collection_roots;
        private WallpaperOcsImports imports = new WallpaperOcsImports();
        private ArrayList<WallpaperOcsChoice> providers = new ArrayList<WallpaperOcsChoice>();
        private ArrayList<WallpaperOcsChoice> categories = new ArrayList<WallpaperOcsChoice>();
        private ArrayList<OcsCard> cards = new ArrayList<OcsCard>();
        // Filter state. "" means "no filter active"; otherwise the matching
        // category id or exactly one active tag must match (AND between the
        // three axes: text, category, tag).
        //
        // The tag axis used to be multi-select (a HashSet of tags feeding
        // card_matches() with AND-logic across the union). That contract
        // was implemented as a FlowBox of Chip widgets -- and Chip clicks
        // proved unreliable on live hardware (only the inner Button hit
        // area received clicks, not the chip's rounded pill background).
        // The operator's fix is to drop the multi-select chip row and use
        // a single-select SelectionRow dropdown instead. libsingularity has
        // no native multi-select dropdown widget, and rolling our own would
        // either duplicate ExpanderRow's machinery or borrow a checkbox
        // pattern that has no precedent in this codebase. We accept the
        // single-select tradeoff: only one tag can be active at a time, and
        // card_matches() still ANDs across text + category + (single) tag,
        // so the same UI affordance -- "narrow the grid to wallpapers
        // carrying exactly one tag I care about" -- is preserved.
        //
        // active_tag_ids stays a HashSet so card_matches() and the
        // rebuild helpers do not need to be rewritten to deal with both the
        // old multi-select and new single-select shapes; SelectionRow sets
        // it to a one-element or empty set.
        private string active_category_id = "";
        private HashSet<string> active_tag_ids = new HashSet<string>();
        // Live union of tags across every card currently in memory. Updated
        // incrementally on add_card(); rebuilt on demand for the dropdown.
        private HashSet<string> known_tag_ids = new HashSet<string>();

        // Provider/category chrome.
        // Provider category row (single-select chip row kept for now: the category
        // axis is naturally a single active value). Below it, the new tag
        // filter is a single-select SelectionRow instead of a chip row -- see
        // the rationale block in initialize() for why the tag axis was
        // downgraded from multi-select chip to single-select dropdown.
        private PreferencesGroup provider_group;
        private PreferencesGroup filter_group;
        private SelectionRow provider_row;
        private SelectionRow tag_row;
        private Box filter_box;
        private FlowBox category_chips;
        private Gtk.SearchEntry search;
        private Button refresh;
        private Button close_button;
        private Spinner spinner;
        private Label status;
        private FlowBox grid;
        private Soup.Session session = new Soup.Session();
        private Cancellable request = new Cancellable();
        private int generation = 0;
        private bool loading = false;
        private bool closed = false;
        private string category_index = "";

        // One card per wallpapers item in the grid. The visible widget is
        // a WallpaperCard (reused from desktop_page.vala so the OCS/Bing
        // grid LOOKS identical to the main wallpaper picker); action button,
        // attribution, and licence text all attach via WallpaperCard's
        // set_action_button() / set_badge() helpers so the visual chrome
        // is owned by the shared class, not duplicated here. Status text
        // for long-running ops (Import / Pin) goes to the global status
        // label rather than a per-card inline message, since WallpaperCard
        // has no room for one.
        private class OcsCard : Object {
            public WallpaperOcsItem item;
            public WallpaperCard card;
            public Button button;
        }

        public WallpaperOcsBrowser(Gtk.Application app, string[] roots) {
            Object(application: app, title: _("Online Wallpapers"), default_width: 880, default_height: 720);
            collection_roots = roots;
            imports.discover(WallpaperCollections.parse(roots));
            session.timeout = 25;
            session.user_agent = "Singularity-Wallpaper-Browser/1";
            // Outer chrome (title + Close) follows the same shape as the
            // desktop_page preferences groups so this window reads as a
            // continuation of the settings panel that launched it.
            var content = new Box(Orientation.VERTICAL, 12);
            content.margin_start = content.margin_end = 20;
            content.margin_top = content.margin_bottom = 16;
            set_child(content);
            var header = new Box(Orientation.HORIZONTAL, 12);
            var title_label = new Label(_("Online Wallpapers"));
            title_label.add_css_class("title-2");
            title_label.hexpand = true;
            title_label.xalign = 0;
            header.append(title_label);
            close_button = new Button.with_label(_("Close"));
            close_button.clicked.connect(() => close());
            header.append(close_button);
            content.append(header);
            var description = new Label(_("Browse and import wallpapers from OCS uploaders. Added packs appear in Wallpaper Source."));
            description.wrap = true;
            description.xalign = 0;
            content.append(description);
            // Provider selection: the same PreferencesGroup + SelectionRow
            // pattern desktop_page.vala uses for the "Wallpaper Source" row.
            // The items list is populated after the helper reports the
            // available providers (see initialize()).
            provider_group = new PreferencesGroup(_("Provider"));
            provider_row = new SelectionRow(_("Online source"), new string[0]);
            provider_group.add_row(provider_row);
            content.append(provider_group);
            // Filters: search box + the post-load chip rows. Categories and
            // tags are both filters over already-loaded items, not gates on
            // loading -- the grid is populated up front by the aggregate crawl.
            filter_box = new Box(Orientation.VERTICAL, 6);
            // Filter UI -- two native Singularity affordances matching the rest of
            // the settings surface: the category axis stays a single-select
            // Chip row (categories are naturally a single active value and
            // work fine on live hardware), the tag axis becomes a single-
            // select SelectionRow dropdown. The multi-select tag chip row
            // was unreliable on live hardware -- Chip clicks only fired on
            // the inner Button, not the chip's rounded pill background --
            // so the operator directed the move to a dropdown here.
            // Tradeoff: only one tag can be active at a time. card_matches()
            // still ANDs across text + category + (single) tag, so the
            // contract of "narrow the grid to wallpapers carrying the tag
            // I care about" is preserved.
            var search_row = new Box(Orientation.HORIZONTAL, 8);
            search = new Gtk.SearchEntry();
            search.placeholder_text = _("Filter loaded wallpapers");
            search.hexpand = true;
            search_row.append(search);
            refresh = new Button.with_label(_("Refresh / Retry"));
            search_row.append(refresh);
            filter_box.append(search_row);
            // Category chips wrap into multiple rows if the catalog has many
            // categories, so a FlowBox rather than a ChipBar (which is
            // horizontal-only and single-active).
            var category_label = new Label(_("Filter by category"));
            category_label.xalign = 0;
            category_label.add_css_class("dim-label");
            filter_box.append(category_label);
            category_chips = new FlowBox();
            category_chips.selection_mode = SelectionMode.NONE;
            category_chips.max_children_per_line = 8;
            category_chips.column_spacing = 6;
            category_chips.row_spacing = 6;
            category_chips.hexpand = true;
            filter_box.append(category_chips);
            // Tag SelectionRow inside a PreferencesGroup so it reads as the
            // same kind of control as the provider row above. Items are
            // populated lazily as the crawl discovers new tags.
            filter_group = new PreferencesGroup(null);
            // Empty item list until the first category streams in; the
            // SelectionRow handles an empty list by showing the expander
            // with no rows (no crash). SelectionRow.selected() is wired in
            // initialize() but only acts once tags exist.
            tag_row = new SelectionRow(_("Tag"), new string[0]);
            filter_group.add_row(tag_row);
            filter_box.append(filter_group);
            content.append(filter_box);
            // Status row: spinner + a count-bearing status line that the
            // aggregate crawl updates as categories stream in.
            var progress = new Box(Orientation.HORIZONTAL, 8);
            spinner = new Spinner();
            progress.append(spinner);
            status = new Label("");
            status.wrap = true;
            status.xalign = 0;
            status.hexpand = true;
            progress.append(status);
            content.append(progress);
            // Grid.
            var scroll = new ScrolledWindow();
            scroll.vexpand = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;
            grid = new FlowBox();
            // Match the main Desktop wallpaper picker's grid surface:
            // .wallpaper-gallery adds the rounded gallery chrome; 2 cols
            // match the sidebar's effective width so the cards (172x104
            // via WallpaperCard) sit at the same density.
            grid.add_css_class("wallpaper-gallery");
            grid.valign = Align.START;
            grid.halign = Align.FILL;
            grid.hexpand = true;
            grid.max_children_per_line = 2;
            grid.min_children_per_line = 2;
            grid.selection_mode = SelectionMode.NONE;
            grid.column_spacing = 14;
            grid.row_spacing = 14;
            grid.margin_top = 10;
            grid.margin_bottom = 10;
            grid.margin_start = 10;
            grid.margin_end = 10;
            scroll.set_child(grid);
            content.append(scroll);
            // Signals. Filter recompute lives on the chip and search box;
            // provider selection drives a fresh aggregate crawl.
            provider_row.selected.connect((id) => { if (!updating) select_provider(id); });
            // Tag SelectionRow callback. SelectionRow emits `selected(id)`
            // when the user picks a row; the first option ("" / no tag
            // selected) clears active_tag_ids. Programmatic rebuilds via
            // rebuild_tag_row() flip `updating` to skip the callback, same
            // pattern provider_row already uses.
            tag_row.selected.connect((id) => { if (!updating) on_tag_row_selected(id); });
            search.search_changed.connect(filter_cards);
            refresh.clicked.connect(() => {
                if (category_index == "") initialize.begin();
                else browse_all.begin();
            });
            close_request.connect(() => {
                if (imports.busy) {
                    status.label = _("Import in progress. You can close this window when it finishes.");
                    return true;
                }
                closed = true;
                generation++;
                request.cancel();
                session.abort();
                dismissed();
                return false;
            });
            var keys = new EventControllerKey();
            keys.key_pressed.connect((key, code, modifiers) => {
                if (key == Gdk.Key.Escape) { close(); return true; }
                return false;
            });
            ((Gtk.Widget) this).add_controller(keys);
            initialize.begin();
        }

        // The SelectionRow callback fires for both user-driven changes (where
        // updating is false) and programmatic rebuilds (where updating is
        // true). The previous bare DropDown code had the same guard; keep it.
        private bool updating = false;

        private void update_controls() {
            search.sensitive = !imports.busy;
            refresh.sensitive = !imports.busy && !loading;
            close_button.sensitive = !imports.busy;
            foreach (var card in cards)
                card.button.sensitive = !imports.busy && !imports.is_added(card.item.key);
            // Filter UI is filter UI, not destructive: a busy import does
            // not warrant disabling it, but a still-loading grid would
            // mean picking a category or tag changes nothing visible, so
            // the category chips disable while loading. The tag SelectionRow
            // stays enabled while loading because its expander is empty
            // (no tags streamed in yet) and disabling a SelectionRow while
            // empty would be confusing.
            category_chips.sensitive = !loading;
            if (loading || imports.busy) spinner.start(); else spinner.stop();
        }

        private static void stop_helper(Subprocess process) {
            // Import invokes ImageMagick children. Stop the whole private process
            // group so a timeout cannot leave a writer running after Retry.
            string? identifier = process.get_identifier();
            int pid = 0;
            if (identifier != null && int.try_parse(identifier, out pid) && pid > 1)
                Posix.kill((Posix.pid_t) (-pid), Posix.Signal.KILL);
            process.force_exit();
        }

        private async string command(string[] argv, Cancellable? cancel, uint timeout) throws Error {
            var launcher = new SubprocessLauncher(SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.set_child_setup(() => { Posix.setsid(); });
            var process = launcher.spawnv(argv);
            bool timed_out = false;
            uint timer = Timeout.add_seconds(timeout, () => {
                timed_out = true;
                stop_helper(process);
                return Source.REMOVE;
            });
            ulong cancel_handler = 0;
            if (cancel != null) {
                cancel_handler = cancel.cancelled.connect(() => stop_helper(process));
                if (cancel.is_cancelled()) stop_helper(process);
            }
            string output;
            string errors;
            try {
                // Drain and reap even after cancellation, then discard the result.
                yield process.communicate_utf8_async(null, null, out output, out errors);
            } catch (Error e) {
                stop_helper(process);
                yield process.wait_async(null);
                throw e;
            } finally {
                if (!timed_out) Source.remove(timer);
                if (cancel_handler != 0) cancel.disconnect(cancel_handler);
            }
            if (cancel != null) cancel.set_error_if_cancelled();
            if (timed_out) throw new IOError.TIMED_OUT(_("Wallpaper request timed out. Try again."));
            if (!process.get_successful()) {
                string detail = errors.strip();
                if (detail.length > 300) detail = detail.substring(0, 300).make_valid();
                throw new IOError.FAILED(detail != "" ? detail : _("Wallpaper helper failed."));
            }
            return output;
        }

        private async void initialize() {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            loading = true;
            status.label = _("Loading wallpaper providers…");
            update_controls();
            try {
                string data = yield command({HELPER, "providers"}, cancel, 30);
                var choices = WallpaperOcs.providers(data);
                uint8[] contents;
                yield File.new_for_path("/usr/share/ncz-wallpapers/ocs-category-index.json").load_contents_async(cancel, out contents, null);
                string index = (string) contents;
                if (gen != generation || closed) return;
                if (choices.size == 0) throw new IOError.FAILED(_("No wallpaper providers available."));
                // Validate before retaining the index so Retry can reload bad data.
                foreach (var choice in choices) WallpaperOcs.categories(index, choice.id);
                providers = choices;
                category_index = index;
                // Append the synthetic Bing pseudo-provider at the END of the
                // real OCS list -- not in WallpaperOcs.providers(), which
                // stays strictly about parsing the OCS helper's JSON. The
                // browser is the only place Bing is glued into the UI; the
                // core parser keeps a hard contract about what "a provider"
                // means over OCS.
                providers.add(new WallpaperOcsChoice(BING_PROVIDER_ID, _("Bing")));
                // Real id/label pairs via set_options(): the id ("bing") is
                // what every downstream check (BING_PROVIDER_ID comparisons
                // in select_provider()/worker()) compares against, and the
                // label ("Bing") is only what's displayed. This USED to be
                // set_items(string[]), whose current-value domain IS the
                // display string -- harmless for the four real OCS
                // providers, where id and label happen to be the same
                // token, but for Bing (id "bing", label "Bing") selecting
                // it in the UI produced current_value == "Bing", which
                // never matched BING_PROVIDER_ID ("bing") anywhere
                // downstream: select_provider() silently fell through to
                // the OCS branch, queried a nonexistent "Bing" OCS
                // provider, and produced zero results ("no images to
                // display") even though the real ncz-wallpaper-bing CLI
                // returns real data. Found by running that CLI directly
                // and tracing why cards.size stayed 0 despite it.
                var provider_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                string initial = providers.size > 0 ? providers[0].id : "";
                foreach (var choice in providers) {
                    string label = choice.id == BING_PROVIDER_ID ? _("Bing") : choice.id;
                    provider_options.add(new Singularity.Core.AppSettingOption() { id = choice.id, label = label });
                    if (choice.id == "pling") initial = choice.id;
                }
                updating = true;
                provider_row.set_options(provider_options);
                provider_row.current_value = initial;
                updating = false;
                loading = false;
                select_provider(initial);
            } catch (Error e) {
                if (gen != generation || closed) return;
                loading = false;
                status.label = _("Could not load wallpaper providers: %s").printf(e.message);
                update_controls();
            }
        }

        // Provider selected -> rebuild the category chip row, then kick off
        // the aggregate crawl for every usable category under that provider.
        // For Bing the "categories" are actually markets fetched from a
        // different helper; the chip row is the same widget, but the
        // underlying command and parser branch.
        private void select_provider(string provider_id) {
            if (provider_id == "") return;
            if (provider_id == BING_PROVIDER_ID) {
                // Bing: drop the OCS category-index gate entirely (the file
                // is irrelevant for Bing) and let select_provider_bing pull
                // markets from the Bing helper. Done in a separate async
                // helper so the synchronous select_provider stays clean.
                select_provider_bing.begin();
                return;
            }
            if (category_index == "") return;
            string selected_provider = provider_id;
            try {
                categories = WallpaperOcs.categories(category_index, selected_provider);
            } catch (Error e) {
                status.label = e.message;
                return;
            }
            // Wipe the active filter when the provider changes -- old chip
            // selections refer to categories that no longer exist.
            active_category_id = "";
            active_tag_ids.clear();
            known_tag_ids.clear();
            rebuild_category_chips();
            rebuild_tag_row();
            cards.clear();
            grid.remove_all();
            update_controls();
            browse_all.begin();
        }

        // Bing equivalent of the OCS provider/category-index load: one
        // synchronous `ncz-wallpaper-bing markets` call, TSV-parsed into the
        // same WallpaperOcsChoice list the chip row already knows how to
        // render. Errors are surfaced through `status` exactly like an OCS
        // category-index parse failure.
        private async void select_provider_bing() {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            loading = true;
            status.label = _("Loading Bing markets…");
            update_controls();
            try {
                string data = yield command({BING_HELPER, "markets"}, cancel, 30);
                if (gen != generation || closed) return;
                categories = WallpaperBing.markets(data);
                active_category_id = "";
                active_tag_ids.clear();
                known_tag_ids.clear();
                rebuild_category_chips();
                rebuild_tag_row();
                cards.clear();
                grid.remove_all();
                loading = false;
                update_controls();
                browse_all.begin();
            } catch (Error e) {
                if (gen != generation || closed) return;
                loading = false;
                status.label = _("Could not load Bing markets: %s").printf(e.message);
                update_controls();
            }
        }

        // Build a row of category filter chips from the cached list. First
        // chip is "All categories" (id ""), then one chip per usable category
        // sorted alphabetically by display name. Only one category can be
        // active at a time -- the chip row drives a single category filter.
        private void rebuild_category_chips() {
            category_chips.remove_all();
            add_filter_chip(category_chips, "", _("All categories"), "", true);
            foreach (var choice in categories)
                add_filter_chip(category_chips, choice.id, choice.name, "", false);
        }

        // Add a single Chip to the category FlowBox. The category chip row
        // is the only chip-based filter left: categories are naturally
        // single-select (single-active) and ChipBar.set_active() works fine
        // for them, but we use raw Chips in a FlowBox because the catalog
        // can have arbitrarily many categories and ChipBar is horizontal-
        // scroll only. Tags moved to SelectionRow (see tag_row above); the
        // tag chip wiring lives in on_tag_chip_clicked() for the duration
        // of this commit and is then dropped.
        private void add_filter_chip(FlowBox host, string id, string label, string icon_name, bool active) {
            var chip = new Singularity.Widgets.Chip(id, icon_name);
            chip.set_label(label);
            chip.active = active;
            chip.activated.connect(() => {
                // Categories are single-select only (radio). Tags moved off
                // chips entirely; see on_tag_chip_clicked / on_tag_row_selected.
                on_category_chip_clicked(id);
                filter_cards();
            });
            // Close (×) is decorative-only for filter chips; do nothing on
            // click so a stray click can't degrade the filter UI silently.
            chip.close_requested.connect(() => {});
            host.append(chip);
        }

        private void on_category_chip_clicked(string id) {
            active_category_id = id;
            // Repaint every chip's active state to match the single-select
            // contract: only the clicked chip stays highlighted.
            repaint_chips(category_chips, (chip) => chip.chip_id == id);
        }

        // Drop-in replacement for the old multi-select on_tag_chip_clicked.
        // SelectionRow is single-select so this just toggles one entry: if
        // the user re-selects the active tag, clear it (back to "all tags");
        // otherwise swap the active tag. active_tag_ids remains a HashSet so
        // card_matches() can AND across it without shape changes.
        private void on_tag_row_selected(string id) {
            if (id == "") {
                active_tag_ids.clear();
            } else if (id in active_tag_ids) {
                active_tag_ids.remove(id);
            } else {
                active_tag_ids.clear();
                active_tag_ids.add(id);
            }
            filter_cards();
        }

        // Local predicate delegate: takes a Chip and returns whether it
        // should be highlighted right now. Used by repaint_chips() to keep
        // the category filter row honest about which chip is "active".
        private delegate bool ChipActivePredicate(Singularity.Widgets.Chip chip);

        // Walk every direct child of `host`, casting each one to a Chip and
        // running `should_be_active` to decide its `active` property. GTK4
        // containers no longer expose a bulk get_children() helper, so the
        // walk is over get_first_child()/get_next_sibling().
        private void repaint_chips(Gtk.Widget host, ChipActivePredicate should_be_active) {
            Gtk.Widget? w = host.get_first_child();
            while (w != null) {
                var chip = w as Singularity.Widgets.Chip;
                if (chip != null) chip.active = should_be_active(chip);
                w = w.get_next_sibling();
            }
        }

        // The aggregate crawl. Pulls a single page from every usable category
        // for the selected provider, in parallel bounded by CRAWL_WORKERS,
        // then merges results into the grid. Live progress ("Loaded K of N
        // categories · M wallpapers so far") is reported through `status`
        // each time a category finishes. The Cancellable cuts the rest of
        // the crawl off cleanly when the user closes the window or starts a
        // fresh crawl.
        private async void browse_all() {
            int gen = ++generation;
            request.cancel();
            request = new Cancellable();
            var cancel = request;
            if (provider_row.current_value == "") {
                loading = false;
                status.label = _("No usable wallpaper providers.");
                update_controls();
                return;
            }
            string provider = provider_row.current_value;
            // Snapshot the category list under the current generation so a
            // provider change mid-crawl cannot mutate the work queue.
            var todo = new ArrayList<string>();
            foreach (var c in categories) todo.add(c.id);
            int total = todo.size;
            cards.clear();
            grid.remove_all();
            known_tag_ids.clear();
            rebuild_tag_row();
            if (total == 0) {
                loading = false;
                status.label = _("No usable wallpaper categories for this provider.");
                update_controls();
                return;
            }
            loading = true;
            status.label = _("Loading %d categories…").printf(total);
            update_controls();
            // Shared crawl state -- heap-allocated so the workers can read
            // it; counters + queue are protected by the mutexes inside it.
            var state = new CrawlState();
            state.generation = gen;
            state.provider = provider;
            state.todo = todo;
            state.total = total;
            state.cancel = cancel;
            // Pool of workers. Each worker pulls one id off the shared
            // queue at a time until it is drained; an outer fan-out starts
            // up to CRAWL_WORKERS at once.
            worker.begin(state);
            for (int i = 1; i < CRAWL_WORKERS && i < total; i++)
                worker.begin(state);
            // Wait for the crawl to finish. We poll once per 100 ms via a
            // GLib.Timeout callback so the main loop keeps painting (spinner,
            // status, thumbnails) between worker yields. Vala has no
            // built-in "wait until" primitive on GLib.MainLoop, hence the
            // explicit poll loop.
            while (gen == generation && state.done_count < total && !closed && !cancel.is_cancelled()) {
                state.count_lock.lock();
                int snapshot;
                try { snapshot = state.item_count; } finally { state.count_lock.unlock(); }
                if (snapshot >= CRAWL_ITEM_CAP) {
                    request.cancel();
                    break;
                }
                bool woken = false;
                Timeout.add(100, () => {
                    woken = true;
                    return Source.REMOVE;
                });
                // Bare yield returns the async function to the GLib main
                // loop, which both runs the Timeout callback above AND
                // reschedules the other worker coroutines. The loop keeps
                // yielding until the timeout fires and flips `woken`.
                while (!woken) yield;
            }
            if (gen != generation || closed) return;
            loading = false;
            filter_cards();
            update_controls();
            // Three bounded streaming requests, never one worker per tile.
            for (int i = 0; i < 3; i++) thumbnails.begin(i, gen, cancel);
        }

        // Shared, heap-allocated crawl state. Vala forbids ref/out parameters
        // on async methods, so the worker pool pulls counters and the
        // pending-queue through this object instead of by reference.
        // Multiple workers may touch it concurrently; the two mutexes in
        // CrawlState serialise the queue pull and the counters.
        private class CrawlState : Object {
            public int generation;
            public string provider;
            public ArrayList<string> todo = new ArrayList<string>();
            public int next_index;
            public int done_count;
            public int item_count;
            public int total;
            public Cancellable cancel;
            public Mutex todo_lock = new Mutex();
            public Mutex count_lock = new Mutex();
        }

        // One worker in the bounded crawl pool. Pulls ids off the shared
        // todo queue inside CrawlState, runs the per-category browse, and
        // merges results back into the same state. The per-category browse
        // itself runs one subprocess per call via the existing command()
        // helper, so no extra concurrency limiter is needed there.
        private async void worker(CrawlState state) {
            // Read everything through state.X; never capture local refs.
            while (state.generation == generation && !closed && !state.cancel.is_cancelled()) {
                int my_index = 0;
                state.todo_lock.lock();
                try {
                    if (state.next_index >= state.todo.size) {
                        return;
                    }
                    my_index = state.next_index++;
                } finally {
                    state.todo_lock.unlock();
                }
                // Pre-check the cap so we never even spawn the subprocess
                // for a category we are going to discard.
                state.count_lock.lock();
                bool cap_hit = false;
                try {
                    if (state.item_count >= CRAWL_ITEM_CAP) cap_hit = true;
                } finally {
                    state.count_lock.unlock();
                }
                if (cap_hit) {
                    state.count_lock.lock();
                    int d;
                    try { d = ++state.done_count; } finally { state.count_lock.unlock(); }
                    Idle.add(() => {
                        if (state.generation == generation) status.label = _("Loaded %d/%d categories · %d wallpapers (cap reached)").printf(d, state.total, state.item_count);
                        return Source.REMOVE;
                    });
                    return;
                }
                string category = state.todo[my_index];
                bool new_tag = false;
                string? error = null;
                try {
                    string data;
                    Gee.ArrayList<WallpaperOcsItem> items;
                    if (state.provider == BING_PROVIDER_ID) {
                        // No --pages / pagination concept for Bing: one
                        // `list <market>` call returns everything archived
                        // for that market, already bounded by the existing
                        // retention window. CRAWL_CATEGORY_TIMEOUT still
                        // applies so a single slow market cannot stall a
                        // worker beyond the user's patience.
                        data = yield command({BING_HELPER, "list", category}, state.cancel, CRAWL_CATEGORY_TIMEOUT);
                        if (state.generation != generation || closed || state.cancel.is_cancelled()) return;
                        items = WallpaperBing.items(data);
                        // For Bing, `category` IS the market id and the
                        // item_category map uses it as the filter key the
                        // same way OCS does (chip row -> string equality
                        // against item_category[key]).
                    } else {
                        data = yield command({HELPER, "browse", state.provider, category, "--pages", "1"}, state.cancel, CRAWL_CATEGORY_TIMEOUT);
                        if (state.generation != generation || closed || state.cancel.is_cancelled()) return;
                        items = WallpaperOcs.items(data, state.provider, category);
                    }
                    foreach (var item in items) {
                        // Re-check the cap under the lock so two workers
                        // can never both push past it on the last item.
                        state.count_lock.lock();
                        bool overflow = false;
                        try {
                            if (state.item_count >= CRAWL_ITEM_CAP) {
                                overflow = true;
                            } else {
                                state.item_count++;
                            }
                        } finally {
                            state.count_lock.unlock();
                        }
                        if (overflow) break;
                        add_card(item, category, out new_tag);
                    }
                } catch (Error e) {
                    if (e is GLib.IOError.CANCELLED) return;
                    error = e.message;
                }
                state.count_lock.lock();
                int d;
                int snap;
                try { d = ++state.done_count; snap = state.item_count; } finally { state.count_lock.unlock(); }
                // Status + tag chip updates live on the main thread. The
                // captured `d`/`snap`/`category`/`error`/`new_tag` are
                // local-scope value captures -- safe to use in the Idle
                // callback that fires after this async function yields.
                Idle.add(() => {
                    if (state.generation != generation) return Source.REMOVE;
                    if (error != null) {
                        // One bad category must not block the others; just
                        // surface it in the status line alongside the count.
                        status.label = _("Loaded %d/%d categories · %d wallpapers · %s failed: %s").printf(d, state.total, snap, category, error);
                    } else {
                        status.label = _("Loaded %d/%d categories · %d wallpapers so far").printf(d, state.total, snap);
                    }
                    if (new_tag) rebuild_tag_row();
                    return Source.REMOVE;
                });
            }
        }

        // (Re)build the tag SelectionRow's option list from the live tag union.
        // Tags are derived from the loaded data, never hardcoded. The first
        // option is "Any tag" (id "" -> clears the filter); the rest are
        // sorted alphabetically by tag id. active_tag_ids is intentionally
        // preserved across rebuilds so a tag the user has already picked
        // survives the next category that streams in -- the SelectionRow
        // keeps showing whichever single tag is currently in active_tag_ids,
        // or "Any tag" if the set is empty.
        //
        // We use set_options (id + label) rather than set_items (label only)
        // because "Any tag" needs to map back to id "" for the filter to
        // clear cleanly: the SelectionRow callback hands us back the *label*
        // string, so an empty string and a friendly label "Any tag" must be
        // resolved through an explicit id.
        private void rebuild_tag_row() {
            var sorted = new ArrayList<string>();
            foreach (var id in known_tag_ids) sorted.add(id);
            sorted.sort((a, b) => a.collate(b));
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            options.add(new Singularity.Core.AppSettingOption() { id = "", label = _("Any tag") });
            foreach (var id in sorted) {
                options.add(new Singularity.Core.AppSettingOption() { id = id, label = id });
            }
            // Resolve the row's current value to the id domain (not the
            // label) so set_options() can match it after the rebuild.
            string current_id = active_tag_ids.size > 0 ? active_tag_ids.to_array()[0] : "";
            updating = true;
            tag_row.set_options(options);
            tag_row.current_value = current_id;
            updating = false;
        }

        private void filter_cards() {
            string query = search.text.strip().casefold();
            int count = 0;
            foreach (var card in cards) {
                bool matches = card_matches(card.item, query, active_category_id, active_tag_ids);
                card.card.visible = matches;
                if (matches) count++;
            }
            if (!loading && !imports.busy) {
                if (cards.size == 0) status.label = _("No importable wallpapers for this provider.");
                else if (count == 0) status.label = _("No matches among loaded wallpapers. Clear the filter or refresh.");
                else status.label = _("%d wallpapers shown · %d loaded").printf(count, cards.size);
            }
        }

        // AND across all three filter axes: text contains-match against
        // name + author, the card's provider-mapped category equals the
        // active category (or no active filter), and the card has every
        // active tag. The card's own category lives on the item; we look
        // it up via the items' positions in the per-category crawl by
        // stashing it on the item at add_card time. (Provider+id is the
        // existing key; we add a `category_id` side-channel via a
        // separate map so the model stays clean.)
        // Stash the source category alongside each card so the chip-row
        // category filter can match it. Gee.HashMap has no try_get; the
        // contains-then-index idiom is the standard substitute.
        private HashMap<string, string> item_category = new HashMap<string, string>();
        private bool card_matches(WallpaperOcsItem item, string query, string active_category, HashSet<string> active_tags) {
            if (active_category != "") {
                if (!item_category.has_key(item.key)) return false;
                string cat = item_category[item.key];
                if (cat == null || cat != active_category) return false;
            }
            foreach (var t in active_tags) if (!(t in item.tags)) return false;
            if (query != "")
                return (item.name + " " + item.author).casefold().contains(query);
            return true;
        }


        // (Re)build a card for one wallpapers item. The visible chrome is a
        // WallpaperCard (visual parity with the main Desktop wallpaper
        // picker -- same 172x104 clipped rounded frame, same Picture with
        // ContentFit.COVER, same title overlay with object-select check,
        // same wallpaper-card / workspace-preview CSS classes). Action
        // button (Import / Pin) attaches through WallpaperCard.set_action_
        // button() so the visual chrome stays consistent with the local
        // picker's trash button. Attribution + licence live as a small
        // badge on the card via WallpaperCard.set_badge().
        private void add_card(WallpaperOcsItem item, string source_category, out bool new_tag_added) {
            new_tag_added = false;
            item_category.set(item.key, source_category);
            foreach (var t in item.tags) if (known_tag_ids.add(t)) new_tag_added = true;
            var card = new OcsCard();
            card.item = item;
            // Use placeholder_only: the OCS browser drives its own async
            // thumbnail load (with generation/close guards) via load_one_
            // thumbnail() rather than letting WallpaperCard's built-in
            // worker handle it (which has no generation awareness).
            string card_title = item.name != "" ? item.name : (item.provider == BING_PROVIDER_ID ? _("Bing wallpaper") : _("Wallpaper"));
            card.card = new WallpaperCard.placeholder_only(item.key, card_title);
            // Attribution / licence badge. OCS shows uploader · provider;
            // Bing shows market · "Bing". Honour dim-label style so the
            // badge reads as supporting text, not primary title.
            string attribution;
            if (item.provider == BING_PROVIDER_ID)
                attribution = "%s · %s".printf(_("Bing"), item.market != "" ? item.market : item.provider);
            else
                attribution = "%s · %s".printf(item.author != "" ? item.author : _("Unknown uploader"), item.provider);
            string license_text = item.license != "" ? item.license : _("No license stated");
            card.card.set_badge(attribution + "  ·  " + license_text);
            // Card click: WallpaperCard emits clicked() on the GestureClick
            // wired in build_card(); for OCS/Bing this is purely a visual
            // affordance -- the meaningful user action is Import / Pin --
            // so we leave it unconnected. The checkmark stays decorative.
            // Action button (Import / Pin / Added / Pinned).
            if (item.provider == BING_PROVIDER_ID) {
                // Pin/Pinned: the image is already part of a persistent
                // Wallpaper Source the moment it was archived; toggling
                // this just protects it from the retention-pruning timer.
                // No WallpaperOcsImports involvement, no copy, no new
                // pack: explicit operator decision not to misattribute
                // a Bing photo into the "Imported from OCS" collection.
                card.button = new Button.with_label(item.pinned ? _("Pinned") : _("Pin"));
            } else {
                card.button = new Button.with_label(imports.is_added(item.key) ? _("Added") : _("Import"));
            }
            card.button.clicked.connect(() => {
                if (item.provider == BING_PROVIDER_ID) pin_card.begin(card);
                else                                  import_card.begin(card);
            });
            card.card.set_action_button(card.button);
            grid.append(card.card);
            cards.add(card);
        }

        // Async thumbnail loader, fanned out 3-at-a-time from browse_all().
        // Two source paths:
        //   * Bing items: thumbnail_path is a local file (helper pre-
        //     downloaded the 400x240 JPEG before the `list` response was
        //     built). Read the bytes, then decode via MemoryInputStream so
        //     the loader does not block on the open InputStream (passing
        //     an already-open stream to from_stream_at_scale_async can
        //     deadlock on the read loop -- the loader assumes it owns the
        //     stream and reads it synchronously until EOF).
        //   * OCS items: item.preview is a remote URL, fetched via Soup.
        //   * Either path failure just leaves the placeholder visible;
        //     a missing preview must not prevent browsing or importing.
        //
        // Each thumbnail write is marshalled onto the main thread via
        // Idle.add() so the Picture widget's set_paintable is always
        // called from the UI thread (GTK4 widget APIs are not safe to
        // call from arbitrary worker contexts).
        private async void thumbnails(int start, int gen, Cancellable cancel) {
            for (int i = start; i < cards.size && gen == generation && !closed && !cancel.is_cancelled(); i += 3) {
                var card = cards[i];
                Gdk.Pixbuf? pixbuf = null;
                if (card.item.thumbnail_path != "") {
                    // Bing local-file path.
                    try {
                        var file = File.new_for_path(card.item.thumbnail_path);
                        if (!file.query_exists()) {
                            show_thumb_unavailable(card);
                            continue;
                        }
                        var stream = yield file.read_async(Priority.DEFAULT, cancel);
                        // Drain to a ByteArray so we own the bytes: the
                        // loader does not have to fight an open file
                        // descriptor for sync reads.
                        var bytes = new ByteArray();
                        try {
                            while (true) {
                                var part = yield stream.read_bytes_async(65536, Priority.DEFAULT, cancel);
                                if (part.get_size() == 0) break;
                                if (bytes.len + part.get_size() > 4 * 1024 * 1024) {
                                    throw new IOError.FAILED("Thumbnail exceeds size limit");
                                }
                                bytes.append(part.get_data());
                            }
                        } finally {
                            // Vala forbids `yield` inside finally, so the
                            // close is a plain call: a non-cancellable
                            // close on a Cancellable-bound stream is
                            // acceptable here -- we're throwing it away.
                            try { stream.close(); } catch (Error e) {}
                        }
                        if (cancel.is_cancelled()) continue;
                        var input = new MemoryInputStream.from_bytes(ByteArray.free_to_bytes((owned) bytes));
                        pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 344, 208, true, cancel);
                    } catch (Error e) {
                        if (!(e is GLib.IOError.CANCELLED)) show_thumb_unavailable(card);
                        continue;
                    }
                } else {
                    // OCS Soup path.
                    string url = card.item.preview;
                    if (!url.has_prefix("https://") && !url.has_prefix("http://")) continue;
                    var message = new Soup.Message("GET", url);
                    if (message == null) continue;
                    InputStream? stream = null;
                    bool skip_card = false;
                    try {
                        stream = yield session.send_async(message, Priority.DEFAULT, cancel);
                        if (cancel.is_cancelled()) { skip_card = true; }
                        else if (message.status_code != 200) { skip_card = true; }
                        else {
                            var bytes = new ByteArray();
                            while (true) {
                                var part = yield stream.read_bytes_async(65536, Priority.DEFAULT, cancel);
                                if (part.get_size() == 0) break;
                                if (bytes.len + part.get_size() > 4 * 1024 * 1024) {
                                    throw new IOError.FAILED("Thumbnail exceeds size limit");
                                }
                                bytes.append(part.get_data());
                            }
                            var input = new MemoryInputStream.from_bytes(ByteArray.free_to_bytes((owned) bytes));
                            pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 344, 208, true, cancel);
                        }
                    } catch (Error e) {
                        if (!(e is GLib.IOError.CANCELLED)) show_thumb_unavailable(card);
                        skip_card = true;
                    } finally {
                        // Synchronous close() (not close_async()) because
                        // Vala forbids yield inside finally. Soup response
                        // streams are safe to close synchronously.
                        if (stream != null) {
                            try { stream.close(); } catch (Error e) {}
                        }
                    }
                    if (skip_card) continue;
                }
                if (pixbuf == null) continue;
                if (gen != generation || closed || cancel.is_cancelled()) continue;
                // Marshal the paintable assignment onto the main thread so
                // Picture.set_paintable is always called from a UI context.
                // The local var capture is safe: pixbuf is a fresh heap
                // object and `card` is a strong ref into the cards[] list.
                Gdk.Pixbuf captured_pb = pixbuf;
                OcsCard captured_card = card;
                Idle.add(() => {
                    if (gen == generation && !closed && captured_card.card != null)
                        captured_card.card.set_paintable(Gdk.Texture.for_pixbuf(captured_pb));
                    return GLib.Source.REMOVE;
                });
            }
        }

        // Surface a "preview unavailable" tooltip on the card without
        // touching the picture's paintable (the placeholder stays
        // visible). Marshalled to the main thread so it can run from any
        // async context safely.
        private void show_thumb_unavailable(OcsCard card) {
            Idle.add(() => {
                if (generation >= 0 && !closed && card.card != null) {
                    // Tooltip on the WallpaperCard itself rather than on
                    // an internal Picture -- the picture is private.
                    card.card.tooltip_text = _("Preview unavailable");
                }
                return GLib.Source.REMOVE;
            });
        }

        // Toggle pin/unpin for a Bing card. The helper takes
        // "<market> <yyyymmdd>" with the date as a separate positional,
        // so we split item.id (which the parser composes as
        // "<market>:<date>") on the first colon and argv that to the
        // helper. No file copy, no new pack, no WallpaperOcsImports --
        // this is the entire Bing per-item action: write or remove a
        // .pinned marker file so the retention timer skips this image.
        //
        // Status text lives on the global status label (card.message used
        // to be a per-card line; with WallpaperCard the card surface no
        // longer has room for an inline message label, and the global
        // status line is what the user watches for long-running ops).
        private async void pin_card(OcsCard card) {
            int colon = card.item.id.index_of(":");
            if (colon <= 0 || colon >= card.item.id.length - 1) {
                status.label = _("Invalid Bing item identity");
                return;
            }
            string market = card.item.id.substring(0, colon);
            string date = card.item.id.substring(colon + 1);
            string[] verb = card.item.pinned ? new string[] {"unpin"} : new string[] {"pin"};
            card.button.label = card.item.pinned ? _("Unpinning…") : _("Pinning…");
            status.label = card.item.pinned ? _("Unpinning Bing image…") : _("Pinning Bing image…");
            update_controls();
            try {
                // Pass a fresh Cancellable (null) so a pending browse-all
                // cancellation cannot also kill the user's explicit pin
                // click. Pin/unpin is a deliberate single-step op; a
                // 15-second budget is generous and protects against a
                // wedged helper.
                yield command({BING_HELPER, verb[0], market, date}, null, 15);
                card.item.pinned = !card.item.pinned;
                card.button.label = card.item.pinned ? _("Pinned") : _("Pin");
                status.label = card.item.pinned
                    ? _("Bing image pinned.")
                    : _("Bing image unpinned.");
            } catch (Error e) {
                status.label = _("Pin toggle failed: %s").printf(e.message);
            }
            update_controls();
        }

        private async void import_card(OcsCard card) {
            if (!imports.begin(card.item.key)) return;
            card.button.label = _("Importing…");
            status.label = _("Downloading and preparing wallpaper pack…");
            update_controls();
            try {
                string data = yield command({HELPER, "import", card.item.provider, card.item.id}, null, 600);
                imports.complete(card.item.key, data, collection_roots);
                card.button.label = _("Added");
                status.label = _("Pack added. Choose it in Wallpaper Source.");
                imported();
            } catch (Error e) {
                imports.fail(card.item.key);
                card.button.label = _("Retry import");
                status.label = _("Import failed: %s").printf(e.message);
            }
            update_controls();
        }
    }
}