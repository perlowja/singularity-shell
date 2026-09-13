# Singularity Shell

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

The desktop shell for the Singularity Desktop Environment: the panel, dock,
overview, sidebar, notifications, run dialog, app switcher, lock screen, and
the compositor integration that drives `labwc`.

This builds the main `singularity-desktop` executable along with the
`singularity-region-picker`, `singularity-keyboard-reset`, and
`singularity-screenshot` helpers.

## Requirements

- [Meson](https://mesonbuild.com/) >= 0.59
- [Vala](https://vala.dev/) compiler
- GTK4, gtk4-layer-shell, wayland-client, wayland-scanner
- VTE (`vte-2.91-gtk4`), GtkSourceView 5, poppler-glib
- NetworkManager (`libnm`), UPower, PulseAudio, GNOME Online Accounts
- polkit, gnome-desktop-4, libsoup-3.0, json-glib, libpeas-2
- dbusmenu-glib, atspi-2, tracker-sparql-3.0, gudev-1.0
- PAM (`libpam`, lock screen authentication)
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-shell. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
