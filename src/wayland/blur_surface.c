/*
 * blur_surface.c - Client-side helper to request compositor background blur
 *
 * Binds the zsingularity_blur_manager_v1 Wayland protocol on the GDK display
 * connection and requests blur for a specific GtkWindow surface.
 *
 * Usage from Vala:
 *   singularity_request_surface_blur(window, 20);
 *
 * This must be called after the window is realized (so that its wl_surface
 * exists). The GDK Wayland display is used to ensure we operate on the same
 * connection as GTK.
 */

#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include <gtk/gtk.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-blur-unstable-v1-client-protocol.h"
#include "blur_surface.h"

#ifdef GDK_WINDOWING_WAYLAND

/* Per-display cache of the blur manager proxy */
static struct zsingularity_blur_manager_v1 *cached_blur_manager = NULL;
static struct wl_display *cached_wl_display = NULL;
static const char *blur_data_key = "singularity-surface-blur";
static const char *blur_signal_key = "singularity-surface-blur-signal";

static void
destroy_surface_blur(GtkWidget *widget, gpointer user_data)
{
	(void)user_data;
	struct zsingularity_blur_v1 *blur =
		g_object_get_data(G_OBJECT(widget), blur_data_key);
	if (!blur) {
		return;
	}

	zsingularity_blur_v1_destroy(blur);
	g_object_set_data(G_OBJECT(widget), blur_data_key, NULL);
}

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
	const char *interface, uint32_t version)
{
	struct zsingularity_blur_manager_v1 **manager = data;
	if (strcmp(interface, zsingularity_blur_manager_v1_interface.name) == 0) {
		*manager = wl_registry_bind(registry, name,
			&zsingularity_blur_manager_v1_interface, 1);
	}
}

static void
registry_global_remove(void *data, struct wl_registry *registry,
	uint32_t name)
{
	/* nothing */
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static struct zsingularity_blur_manager_v1 *
get_blur_manager(struct wl_display *wl_display)
{
	/* Return cached manager if we already probed this display */
	if (wl_display == cached_wl_display) {
		return cached_blur_manager;
	}

	struct zsingularity_blur_manager_v1 *manager = NULL;
	struct wl_registry *registry = wl_display_get_registry(wl_display);
	wl_registry_add_listener(registry, &registry_listener, &manager);
	wl_display_roundtrip(wl_display);
	wl_registry_destroy(registry);

	cached_wl_display = wl_display;
	cached_blur_manager = manager;
	return manager;
}

#endif /* GDK_WINDOWING_WAYLAND */

/*
 * Request compositor-level background blur for a GTK window.
 *
 * @window: the GtkWindow to blur behind (must be realized)
 * @radius: blur radius in pixels (0 = disable)
 */
void
singularity_request_surface_blur(GtkWidget *widget, uint32_t radius)
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

	struct wl_display *wl_display =
		gdk_wayland_display_get_wl_display(GDK_WAYLAND_DISPLAY(gdk_display));
	struct zsingularity_blur_manager_v1 *manager =
		get_blur_manager(wl_display);
	if (!manager) {
		/* Compositor doesn't support the blur protocol */
		return;
	}

	struct wl_surface *wl_surface =
		gdk_wayland_surface_get_wl_surface(GDK_WAYLAND_SURFACE(gdk_surface));
	if (!wl_surface) {
		return;
	}

	struct zsingularity_blur_v1 *blur =
		g_object_get_data(G_OBJECT(widget), blur_data_key);
	if (!blur) {
		blur = zsingularity_blur_manager_v1_get_blur(manager, wl_surface);
		g_object_set_data(G_OBJECT(widget), blur_data_key, blur);
		if (!g_object_get_data(G_OBJECT(widget), blur_signal_key)) {
			g_signal_connect(widget, "unrealize",
				G_CALLBACK(destroy_surface_blur), NULL);
			g_object_set_data(G_OBJECT(widget), blur_signal_key,
				GINT_TO_POINTER(1));
		}
	}
	zsingularity_blur_v1_set_radius(blur, radius);
	zsingularity_blur_v1_set_noise(blur, 0);
	zsingularity_blur_v1_commit(blur);

#else
	(void)widget;
	(void)radius;
#endif
}

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
