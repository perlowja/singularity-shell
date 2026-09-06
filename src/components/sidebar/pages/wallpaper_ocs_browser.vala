using Gtk;
using Gee;
using Singularity.Widgets;

namespace Singularity.Shell {
    // Presentation only: the installed helper owns all OCS and import policy.
    public class WallpaperOcsBrowser : Gtk.Window {
        public signal void imported();
        public signal void dismissed();
        private const string HELPER = "/usr/local/bin/ncz-wallpaper-ocs";
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
        // category id or one or more tags must match (AND between the three
        // axes: text, category, tag set).
        private string active_category_id = "";
        private HashSet<string> active_tag_ids = new HashSet<string>();
        // Live union of tags across every card currently in memory. Updated
        // incrementally on add_card(); rebuilt on demand for the chip row.
        private HashSet<string> known_tag_ids = new HashSet<string>();

        // Provider/category chrome.
        private PreferencesGroup provider_group;
        private SelectionRow provider_row;
        private Box filter_box;
        private FlowBox category_chips;
        private FlowBox tag_chips;
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

        private class OcsCard : Object {
            public WallpaperOcsItem item;
            public FlowBoxChild child;
            public Picture picture;
            public Button button;
            public Label message;
            public Spinner spinner;
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
            // horizontal-only and single-active). Raw `Chip` widgets in a
            // FlowBox are used here AND for tags; reasoning recorded in the
            // commit message. The visible close (×) on each chip is a
            // widget-rendering fact of libsingularity's Chip that cannot be
            // suppressed; for filter chips it is wired to a no-op so it does
            // not silently do something surprising like "delete this tag".
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
            var tag_label = new Label(_("Filter by tag"));
            tag_label.xalign = 0;
            tag_label.add_css_class("dim-label");
            filter_box.append(tag_label);
            tag_chips = new FlowBox();
            tag_chips.selection_mode = SelectionMode.NONE;
            tag_chips.max_children_per_line = 10;
            tag_chips.column_spacing = 6;
            tag_chips.row_spacing = 6;
            tag_chips.hexpand = true;
            filter_box.append(tag_chips);
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
            grid.selection_mode = SelectionMode.NONE;
            grid.min_children_per_line = 1;
            grid.max_children_per_line = 3;
            grid.column_spacing = grid.row_spacing = 12;
            grid.valign = Align.START;
            scroll.set_child(grid);
            content.append(scroll);
            // Signals. Filter recompute lives on the chip and search box;
            // provider selection drives a fresh aggregate crawl.
            provider_row.selected.connect((id) => { if (!updating) select_provider(id); });
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
            // Filter chips are filter UI, not destructive: a busy import
            // does not warrant disabling them, but a still-loading grid
            // would mean clicking them changes nothing visible.
            category_chips.sensitive = !loading;
            tag_chips.sensitive = !loading;
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
                // SelectionRow takes a plain string[] of options and a current
                // value. The provider id (e.g. "pling") doubles as both the
                // option key and the visible label until we get fancier
                // branding -- the desktop_page Wallpaper Source row does the
                // same thing for its raw provider token.
                var names = new string[providers.size];
                string initial = providers.size > 0 ? providers[0].id : "";
                for (int i = 0; i < providers.size; i++) {
                    names[i] = providers[i].id;
                    if (providers[i].id == "pling") initial = providers[i].id;
                }
                updating = true;
                provider_row.set_items(names);
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
        private void select_provider(string provider_id) {
            if (provider_id == "" || category_index == "") return;
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
            tag_chips.remove_all();
            cards.clear();
            grid.remove_all();
            update_controls();
            browse_all.begin();
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

        // Add a single Chip to a FlowBox, wiring it as a filter toggle. id is
        // the stable key (category id or tag string); label is the visible
        // text. active_predicate tells us whether the chip should start in
        // the highlighted state. The (×) close button is wired to a no-op so
        // it cannot silently do something surprising (e.g. look like a
        // "delete this tag from existence" affordance).
        private void add_filter_chip(FlowBox host, string id, string label, string icon_name, bool active) {
            var chip = new Singularity.Widgets.Chip(id, icon_name);
            chip.set_label(label);
            chip.active = active;
            chip.activated.connect(() => {
                // Different hosts interpret "active" differently: categories
                // are single-select (radio), tags are multi-select (AND/OR).
                if (host == category_chips) on_category_chip_clicked(id);
                else                          on_tag_chip_clicked(id);
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

        private void on_tag_chip_clicked(string id) {
            if (id in active_tag_ids) active_tag_ids.remove(id);
            else                     active_tag_ids.add(id);
            // Repaint chip active state to reflect the multi-select set.
            repaint_chips(tag_chips, (chip) => chip.chip_id in active_tag_ids);
        }

        // Local predicate delegate: takes a Chip and returns whether it
        // should be highlighted right now. Used by repaint_chips() to keep
        // the two filter rows (single-select category, multi-select tags)
        // honest about which chip is "active".
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
            rebuild_tag_chips(new HashSet<string>());
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
                    string data = yield command({HELPER, "browse", state.provider, category, "--pages", "1"}, state.cancel, CRAWL_CATEGORY_TIMEOUT);
                    if (state.generation != generation || closed || state.cancel.is_cancelled()) return;
                    var items = WallpaperOcs.items(data, state.provider, category);
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
                    if (new_tag) rebuild_tag_chips(known_tag_ids);
                    return Source.REMOVE;
                });
            }
        }

        // (Re)build the tag chip row from the live tag union. Tags are
        // derived from the loaded data, never hardcoded. active_tag_ids is
        // intentionally preserved across rebuilds so a tag the user has
        // already picked survives the next category that streams in.
        private void rebuild_tag_chips(HashSet<string> ids) {
            var sorted = new ArrayList<string>();
            foreach (var id in ids) sorted.add(id);
            sorted.sort((a, b) => a.collate(b));
            tag_chips.remove_all();
            foreach (var id in sorted)
                add_filter_chip(tag_chips, id, id, "", id in active_tag_ids);
        }

        private void filter_cards() {
            string query = search.text.strip().casefold();
            int count = 0;
            foreach (var card in cards) {
                bool matches = card_matches(card.item, query, active_category_id, active_tag_ids);
                card.child.visible = matches;
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


        private void add_card(WallpaperOcsItem item, string source_category, out bool new_tag_added) {
            new_tag_added = false;
            item_category.set(item.key, source_category);
            foreach (var t in item.tags) if (known_tag_ids.add(t)) new_tag_added = true;
            var card = new OcsCard();
            card.item = item;
            card.child = new FlowBoxChild();
            var box = new Box(Orientation.VERTICAL, 6);
            box.set_size_request(220, -1);
            box.margin_start = box.margin_end = 8;
            box.margin_top = box.margin_bottom = 8;
            box.add_css_class("card");
            card.picture = new Picture();
            card.picture.set_size_request(220, 130);
            card.picture.content_fit = ContentFit.COVER;
            card.picture.can_shrink = true;
            var overlay = new Overlay();
            var placeholder = new Image.from_icon_name("image-x-generic-symbolic");
            placeholder.pixel_size = 48;
            overlay.set_child(placeholder);
            overlay.add_overlay(card.picture);
            overlay.set_size_request(220, 130);
            box.append(overlay);
            var name = new Label(item.name);
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.max_width_chars = 26;
            name.tooltip_text = item.name;
            name.add_css_class("heading");
            box.append(name);
            string attribution = "%s · %s".printf(item.author != "" ? item.author : _("Unknown uploader"), item.provider);
            var credit = new Label(attribution);
            credit.xalign = 0;
            credit.ellipsize = Pango.EllipsizeMode.END;
            credit.max_width_chars = 26;
            credit.tooltip_text = attribution;
            box.append(credit);
            var license = new Label(item.license != "" ? item.license : _("No license stated"));
            license.xalign = 0;
            license.ellipsize = Pango.EllipsizeMode.END;
            license.max_width_chars = 26;
            license.tooltip_text = license.label;
            license.add_css_class("dim-label");
            box.append(license);
            // Tag chips on the card surface every per-item tag, mirroring
            // the filter row above. Reusing the raw Chip keeps the visual
            // vocabulary consistent across the window.
            if (item.tags.length > 0) {
                var tag_row = new FlowBox();
                tag_row.selection_mode = SelectionMode.NONE;
                tag_row.max_children_per_line = 4;
                tag_row.column_spacing = 4;
                tag_row.row_spacing = 4;
                foreach (var t in item.tags) {
                    var tag_chip = new Singularity.Widgets.Chip("tag:" + t, null);
                    tag_chip.set_label(t);
                    // Clicking a tag chip on a card jumps straight to that
                    // tag in the filter row. Convenience for the user; the
                    // chip itself stays a passive display element.
                    tag_chip.activated.connect(() => {
                        if (!(t in active_tag_ids)) {
                            active_tag_ids.add(t);
                            rebuild_tag_chips(known_tag_ids);
                            filter_cards();
                        }
                    });
                    tag_chip.close_requested.connect(() => {});
                    tag_row.append(tag_chip);
                }
                box.append(tag_row);
            }
            card.message = new Label("");
            card.message.wrap = true;
            card.message.max_width_chars = 26;
            card.message.xalign = 0;
            box.append(card.message);
            var action = new Box(Orientation.HORIZONTAL, 8);
            card.spinner = new Spinner();
            action.append(card.spinner);
            card.button = new Button.with_label(imports.is_added(item.key) ? _("Added") : _("Import"));
            card.button.hexpand = true;
            card.button.clicked.connect(() => import_card.begin(card));
            action.append(card.button);
            box.append(action);
            card.child.set_child(box);
            grid.append(card.child);
            cards.add(card);
        }

        private async void thumbnails(int start, int gen, Cancellable cancel) {
            for (int i = start; i < cards.size && gen == generation && !closed; i += 3) {
                var card = cards[i];
                string url = card.item.preview;
                if (!url.has_prefix("https://") && !url.has_prefix("http://")) continue;
                try {
                    var message = new Soup.Message("GET", url);
                    if (message == null) continue;
                    var stream = yield session.send_async(message, Priority.DEFAULT, cancel);
                    if (message.status_code != 200) { yield stream.close_async(Priority.DEFAULT, null); continue; }
                    var bytes = new ByteArray();
                    while (true) {
                        var part = yield stream.read_bytes_async(65536, Priority.DEFAULT, cancel);
                        if (part.get_size() == 0) break;
                        if (bytes.len + part.get_size() > 4 * 1024 * 1024) {
                            yield stream.close_async(Priority.DEFAULT, null);
                            throw new IOError.FAILED("Thumbnail exceeds size limit");
                        }
                        bytes.append(part.get_data());
                    }
                    yield stream.close_async(Priority.DEFAULT, null);
                    var input = new MemoryInputStream.from_bytes(ByteArray.free_to_bytes((owned) bytes));
                    var pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async(input, 440, 260, true, cancel);
                    if (gen == generation && !closed) card.picture.paintable = Gdk.Texture.for_pixbuf(pixbuf);
                } catch (Error e) {
                    // A missing preview must not prevent browsing or importing.
                    if (gen == generation && !closed) card.picture.tooltip_text = _("Preview unavailable");
                }
            }
        }

        private async void import_card(OcsCard card) {
            if (!imports.begin(card.item.key)) return;
            card.spinner.start();
            card.button.label = _("Importing…");
            card.message.label = "";
            status.label = _("Downloading and preparing wallpaper pack…");
            update_controls();
            try {
                string data = yield command({HELPER, "import", card.item.provider, card.item.id}, null, 600);
                imports.complete(card.item.key, data, collection_roots);
                card.button.label = _("Added");
                card.message.label = _("Available in Wallpaper Source");
                status.label = _("Pack added. Choose it in Wallpaper Source.");
                imported();
            } catch (Error e) {
                imports.fail(card.item.key);
                card.button.label = _("Retry import");
                card.message.label = _("Could not import: %s").printf(e.message);
                status.label = _("Import failed. You can retry.");
            }
            card.spinner.stop();
            update_controls();
        }
    }
}