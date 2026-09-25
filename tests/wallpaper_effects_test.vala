using GLib;
using Gdk;
using Singularity;

private Pixbuf solid(int width, int height, uint8 r, uint8 g, uint8 b) {
    var pixbuf = new Pixbuf(Colorspace.RGB, true, 8, width, height);
    unowned uint8[] pixels = pixbuf.get_pixels_with_length();
    int stride = pixbuf.get_rowstride();
    int channels = pixbuf.get_n_channels();
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int i = y * stride + x * channels;
            pixels[i] = r;
            pixels[i + 1] = g;
            pixels[i + 2] = b;
            pixels[i + 3] = 255;
        }
    }
    return pixbuf;
}

private void test_settings_roundtrip() {
    var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
    assert(schema != null);
    var settings = new GLib.Settings.full(schema, SettingsBackend.memory_settings_backend_new(), null);
    assert(settings.set_string("wallpaper-effect", "blur"));
    assert(settings.set_int("wallpaper-effect-blur-radius", 16));
    assert(settings.get_string("wallpaper-effect") == "blur");
    assert(settings.get_int("wallpaper-effect-blur-radius") == 16);
}

private void test_grayscale() {
    var result = WallpaperEffects.grayscale(solid(2, 2, 230, 40, 90));
    uint8[] pixels = result.get_pixels_with_length();
    assert(pixels[0] == pixels[1] && pixels[1] == pixels[2]);
    assert(pixels[0] != 230);
}

private void test_blur() {
    var pixbuf = solid(9, 3, 0, 0, 0);
    unowned uint8[] pixels = pixbuf.get_pixels_with_length();
    int stride = pixbuf.get_rowstride();
    int channels = pixbuf.get_n_channels();
    for (int y = 0; y < 3; y++) {
        for (int x = 5; x < 9; x++) {
            int i = y * stride + x * channels;
            pixels[i] = pixels[i + 1] = pixels[i + 2] = 255;
        }
    }
    var result = WallpaperEffects.blur(pixbuf, 1);
    uint8[] blurred = result.get_pixels_with_length();
    int edge = stride + 5 * channels;
    assert(blurred[edge] > 0 && blurred[edge] < 255);
}

private void test_none_keeps_source() {
    var pixbuf = solid(2, 2, 10, 20, 30);
    assert(WallpaperEffects.apply(pixbuf, "none", 8) == pixbuf);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-effects/grayscale", test_grayscale);
    Test.add_func("/wallpaper-effects/blur", test_blur);
    Test.add_func("/wallpaper-effects/none", test_none_keeps_source);
    Test.add_func("/wallpaper-effects/settings-roundtrip", test_settings_roundtrip);
    return Test.run();
}
