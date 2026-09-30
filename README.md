# Negativ

A macOS film-negative scanning app (SwiftUI + Core Image, macOS 14+).

- **Open** (⌘O) – image files (JPEG, TIFF, RAW…) or folders; also by dragging onto the window, dropping on the Dock icon or Finder's Open With. A file opens in its folder's roll.
- **Import** – insert a memory card (any volume with a `DCIM` folder) and the import sheet opens with auto-inverted previews, newest first. Files already in the library are marked and left unselected. Frames are copied into a new roll folder under `~/Pictures/Negativ`.
- **Invert** – colour negative, B&W negative or slide. Inversion works in density (log) space. Levels are set per channel from the cropped frame, which removes the orange mask. You can also measure the film base from the rebate with the eyedropper (B).
- **Geometry** – rotate (⌘[ / ⌘]), flip, straighten ±10°, crop (C) with aspect presets (6×6, 6×7, 645, XPan…).
- **Auto crop** (A) – finds the film frame in the scan and straightens it: rebate, gaps between frames, holder mask and backlight are cropped away. Applies to every frame selected in the filmstrip.
- **Virtual copies** – a scan holding several frames (a strip on a light table) can be split into one frame each (Split, ⇧⌘K), or duplicated by hand (⌘D). Copies share the file and export as `NAME-2`, `NAME-3`…
- **Film type** – B&W film is detected when a roll is opened and set to B&W mode on frames not yet edited.
- **Process** – exposure, contrast, midtones, blacks, whites, print curve, temperature/tint, neutral picker (W), saturation.
- **Colour balance lock** (⇧⌘L) – keeps one frame's measured balance and levels and applies them to the selected frames, for a consistent roll. Changing film type or base unlocks it.
- **Undo / redo** (⌘Z / ⇧⌘Z) – per frame, including batch changes made to it from another frame.
- **Batch** – copy/paste settings (⇧⌘C / ⇧⌘V), sync to the filmstrip selection (⇧⌘S) or the whole roll; ⌘A selects every frame.
- **Export** – JPEG or 16-bit TIFF, full resolution or resized (⌘E), with the scan's capture date and camera data. Can be stopped part-way; never overwrites a scan.

## Keys

| Key | |
|---|---|
| Tab / ⇧Tab, → / ← | Next / previous scan |
| A | Auto crop and straighten (all selected frames) |
| C | Crop tool · R reset crop |
| I | Invert: switch between negative and positive (not inverted) |
| N | Show the raw negative |
| B / W | Pick film base / neutral grey |
| ⌘Z / ⇧⌘Z | Undo / redo |
| Scroll, drag, double-click | Zoom, pan, back to fit |

Edits are saved non-destructively in `.negativ.json` in each roll folder.
RAW files (CR3, NEF, ARW, DNG, RAF…) are decoded linear through `CIRAWFilter`. TIFF, JPEG and HEIC are also supported.

```
./build.sh                 # → build/Negativ.app
build/Negativ.app/Contents/MacOS/Negativ --render <file> <out-folder> [tiff] [--autocrop]   # headless export using the roll's settings
build/Negativ.app/Contents/MacOS/Negativ --detect <files…>   # detected frame rect and tilt per file
build/Negativ.app/Contents/MacOS/Negativ --split <files…>    # every frame found per file
```
