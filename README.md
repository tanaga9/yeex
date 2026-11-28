# YeeX

YeeX is a single-image viewer for Apple Silicon. It uses AppKit for input and ImageIO and Core Graphics to decode and render images. At runtime, it uses macOS frameworks and the system zlib library.

## Build and launch

You need an Apple Silicon Mac running macOS 26 or later. Build with Xcode 26 or later, or the corresponding Command Line Tools.

```sh
./Scripts/build-app.sh
open dist/YeeX.app
```

You can also open `dist/YeeX.app` from Finder or pass an image or folder on the command line.

```sh
open -a "$PWD/dist/YeeX.app" /path/to/images
```

The build script ad hoc signs `YeeX.app` for local testing. If a restricted shell cannot reach the macOS desktop session, launch the app from Finder or a regular Terminal window.

## Publish a release

In GitHub Actions, open **Release YeeX** and choose **Run workflow** from the default branch. Enter a version such as `0.2.0`. Leave the commit field empty to release the default branch's head at the time you start the workflow, or enter the full SHA of a specific commit.

```sh
gh workflow run release.yml -f version=0.2.0
```

The workflow tests the selected commit on Apple Silicon, sets the requested version in its temporary checkout, and verifies the signed app inside the ZIP. It then creates the matching Git tag and publishes the ZIP with generated release notes. An existing release or draft for that version, or a tag pointing at a different commit, stops publication. If a canceled run leaves a draft, remove that draft before retrying. The app is ad hoc signed and is not notarized.

GitHub may require Workflows write permission when creating a tag for an older commit. To support those commits, set the repository Actions secret `YEEX_RELEASE_TAG_TOKEN` to a fine-grained token scoped to this repository with **Contents** and **Workflows** read/write permissions. The workflow uses this token for tag creation.

## Controls

| Action | Shortcut or control |
| --- | --- |
| Open an image or folder | ⌘O or ⇧⌘O, or drag and drop |
| Browse images | Arrow keys, mouse wheel, or trackpad |
| Browse compact thumbnail strips | Both strips are shown by default, below and to the right of the image. Scroll or click a thumbnail. Toggle each strip in the View menu. |
| Change the vertical or horizontal sort order | V or H in the toolbar, or Vertical Sort or Horizontal Sort in the View menu |
| Toggle looping or polling | Loop or Poll in the toolbar or View menu |
| Toggle Free Scroll | View menu |
| Zoom and pan | `+` or `-`, pinch, or scroll and drag while zoomed in |
| Fit the image to the window or show it at actual size | ⌘0 or ⌥⌘1 |
| Fit the window to the image | Double-click the image |
| Copy or move an image | ⌘1–9 or ⇧1–9 |
| Show Info or reload the folder | ⌘I or ⌘R |

Each Cover Flow strip shows up to three images before and three after the selection, depending on available space. WBMP, XBM, and XPM show placeholders in the surrounding slots. Select one of these files to display it in the main viewer. The center thumbnail is generated from the displayed image.

Set folders in the Copy Destinations and Move Destinations panels. Right-click a destination to change or clear it. If the destination already contains a folder or image package with the same name, use **Keep Both** to save under a new name.

YeeX checks that a transfer still refers to the file that was displayed. While moving it, YeeX temporarily holds the original in a **YeeX Move Recovery** folder beside its original location. If a move is interrupted, that folder can contain the original. If YeeX cannot clean up or restore a retained file, the recovery alert can reveal its location in Finder.

For a move between volumes, YeeX checks the held file and any items inside a package before and after copying. If it detects an update before publishing the copy, it restores the original. After a successful copy, YeeX renames the held original into Trash when Trash is on the same volume. Otherwise it keeps the original in **YeeX Move Recovery** and reports its location.

**Replace** applies to the destination file found when the confirmation opens. YeeX stops if a different file takes its place. An interrupted replacement can leave the previous file in a **YeeX Replace Recovery** folder beside the destination.

## Tests and benchmarks

```sh
./Scripts/test.sh
YEEX_BENCHMARK_FOLDER=/path/to/test-images ./Scripts/test.sh -c release --filter benchmarkFolder
```

| Area | Coverage |
| --- | --- |
| Folder scanning and sort order | Incremental single-pass scans, independent axis orders, navigation directions and wrapping, UUIDv5 random order, and insertion and removal in a 30,000-entry index |
| Change detection | Watch events during a successful scan queue a follow-up scan, the first Poll difference triggers a scan, and failed scans preserve the last polling baseline |
| Image formats | Samples for PNG, JPEG, BMP, ICO, TGA, TIFF, AVIF, PNM, GIF and WebP animation frames, PDF, SVG and SVGZ, X11 bitmaps, and PXD and PXM previews |
| AI generation metadata | PNG text and JPEG and WebP EXIF, including Unicode comments, ComfyUI graphs, and Stable Diffusion parameters |
| Copy and move | Collision handling, saving under a new name, and explicit replacement |
| macOS smoke test | App launch, initial image display, the Info panel, and arrow-key navigation |

The benchmark uses small synthetic JPEGs. Real-world workloads, HDD and SMB NAS performance, trackpad feel, and additional format variants still need testing.

Manual reload invalidates the decoded images for the folder. Prefetch skips images with an estimated decoded size above 64 MiB, or above the cache budget if it is smaller. Formats that require a dedicated decoder are loaded when selected.
