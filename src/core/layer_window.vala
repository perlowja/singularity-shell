using Gtk;

namespace Singularity {

    /**
     * Hide a layer-shell window and drop its GdkSurface.
     *
     * GTK keeps one wl_surface alive across hide/show, while gtk4-layer-shell
     * destroys the zwlr_layer_surface_v1 at unmap and creates a NEW one over
     * that same wl_surface on the next open. wl_surface state is persistent, so
     * a frame that lands after the unmap leaves a buffer attached, and creating
     * a layer surface over a surface that still holds a buffer is a client
     * error the compositor answers by killing the connection:
     *
     *     Gdk-Message: Error 71 (Protocol error) dispatching to Wayland display
     *     zwlr_layer_surface_v1 has never been configured
     *
     * Whether the stray frame lands is a race on wl_buffer.release, which is
     * why a window would survive a variable number of open/close cycles before
     * dying. Dropping the GdkSurface means the next open allocates a fresh
     * wl_surface that cannot carry a stale buffer.
     *
     * This is the same sequence gtk4-layer-shell performs internally in
     * gtk_layer_surface_remap(), so it is a supported, exercised path.
     * unrealize() on a never-realized widget is a documented no-op, which makes
     * this safe to call from a constructor-time hide.
     *
     * The cast matters: GtkWindow implements GtkNative, so a bare unrealize()
     * binds to gtk_native_unrealize -- an internal vfunc -- rather than
     * gtk_widget_unrealize. Verified by inspecting the C that valac emits for
     * each spelling.
     */
    public void close_layer_window (Gtk.Window window) {
        ((Gtk.Widget) window).hide ();
        ((Gtk.Widget) window).unrealize ();
    }
}
