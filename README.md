# AppIconBGGenerator

This is a quick app designed to create `macosx_appicon_darkbg26.png` and `macosx_appicon_darkbg27.png` for [matplotlib Issue 31895](https://github.com/matplotlib/matplotlib/issues/31895).

# Methodology

1. Create a blank icon in Icon Composer.
2. Launch app with blank icon.
3. Call `-[NSApplication applicationIconImage]` to fetch the blank icon. Note that this has slightly different metrics than the embedded `.icns` files in the app bundle. As matplotlib uses `-[NSApplication setApplicationIconImage:]`, these are the metrics that we need.
4. Dilate/bleed the pixels surrounding the edge of the squircle. Search for "alpha bleeding", "color bleeding", "edge padding", "alpha dilation" to understand this problem.
5. Save the result as an opaque PNG file.

## License

Public Domain.
