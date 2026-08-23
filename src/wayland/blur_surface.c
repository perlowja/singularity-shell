#define _POSIX_C_SOURCE 200809L

#include <gtk/gtk.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "blur_surface.h"

void
singularity_surface_set_input_passthrough(GtkWidget *widget)
{
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gtk_widget_get_display(widget);
	if (!GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return;
	}

	GdkSurface *gdk_surface = gtk_native_get_surface(GTK_NATIVE(widget));
	if (!gdk_surface || !GDK_IS_WAYLAND_SURFACE(gdk_surface)) {
		return;
	}

	struct wl_compositor *compositor =
		gdk_wayland_display_get_wl_compositor(GDK_WAYLAND_DISPLAY(gdk_display));
	struct wl_surface *wl_surface =
		gdk_wayland_surface_get_wl_surface(GDK_WAYLAND_SURFACE(gdk_surface));
	if (!compositor || !wl_surface) {
		return;
	}

	struct wl_region *empty = wl_compositor_create_region(compositor);
	wl_surface_set_input_region(wl_surface, empty);
	wl_region_destroy(empty);
	wl_surface_commit(wl_surface);
#else
	(void)widget;
#endif
}
