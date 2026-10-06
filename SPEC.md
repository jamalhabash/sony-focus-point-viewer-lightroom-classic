# Focus Point — Lightroom Classic plugin for Sony a7 IV

Show where the camera focused while culling in Lightroom Classic.

## Architecture

Lightroom Classic plugins are Lua (Lightroom SDK). Lua can't parse maker notes
or draw images well, so the work is split:

```
lr-focus-point/
├── flake.nix                 # dev shell + packages + `nix run .#install`
├── Cargo.toml / src/         # Rust CLI `focuspoint`
├── plugin/focuspoint.lrplugin/  # Lua plugin source (Info.lua etc.)
└── SPEC.md
```

`nix build` produces `result/focuspoint.lrplugin/` = Lua sources + `bin/focuspoint`.
`nix run .#install` copies that bundle (not a symlink — real files, chmod u+w) to
`~/Library/Application Support/Adobe/Lightroom/Modules/focuspoint.lrplugin`,
which Lightroom Classic auto-loads on start.

Target: macOS aarch64-darwin primarily (user's machine); flake should also
evaluate for x86_64-darwin / linux for dev. Windows is out of scope, but the Lua
should not hard-break there (use `bin/focuspoint.exe` if `WIN_ENV`).

## Rust CLI contract (`focuspoint`)

```
focuspoint info   <FILE> [--format json|kv]
focuspoint render <FILE> --out-dir <DIR> [--source <JPEG>] [--size <PX>] [--crop-size <PX>] [--format json|kv]
```

* Input files: Sony ARW (TIFF-based), JPEG (Exif APP1). HEIF/HIF (ISOBMFF with
  an `Exif` item) for metadata if feasible. Unknown → `status=unsupported`.
* `info` reads metadata only.
* `render` additionally writes two JPEGs into `--out-dir` (created if missing),
  with **unique file names per invocation** (e.g. include a timestamp/counter —
  Lightroom caches images by path):
  * overview: whole frame, long edge `--size` (default 1600), focus frame drawn
    as a high-contrast box (bright green with dark outline) + small crosshair.
  * crop: square-ish region centred on the focus point, `--crop-size` (default
    800) px, cut from the highest-resolution source available at the largest
    scale it supports (never upscale beyond 1:1 of the source), with the focus
    box drawn too.
  * Image source priority: `--source <JPEG>` if given (assumed to be the full,
    uncropped frame already in *display* orientation — e.g. a Lightroom preview);
    otherwise the largest embedded JPEG in the ARW (PreviewImage / JpgFromRaw),
    or the JPEG file itself. Embedded previews are in *sensor* orientation, so
    apply EXIF Orientation before drawing/saving.
* Output `--format kv` (what the Lua plugin uses): one `key=value` per line,
  UTF-8, values with `\n` / `\\` escaped as `\\n` / `\\\\`. Keys (omit when unknown):

  | key | meaning |
  |---|---|
  | `status` | `ok`, `no_focus` (file parsed, no usable focus point), `unsupported`, `error` |
  | `message` | human-readable reason for non-ok status |
  | `make`, `model` | e.g. `SONY`, `ILCE-7M4` |
  | `orientation` | EXIF orientation 1..8 |
  | `image_width`, `image_height` | the coordinate space of the focus point (from the maker note, sensor orientation) |
  | `focus_x`, `focus_y` | focus point in that space |
  | `frame_width`, `frame_height` | focus frame box size in that space, when known |
  | `norm_x`, `norm_y` | focus point as 0..1 fractions of the **displayed** (orientation-applied) frame |
  | `norm_w`, `norm_h` | frame size as fractions of the displayed frame |
  | `focus_mode` | e.g. `AF-C`, `AF-S`, `DMF`, `MF` |
  | `af_area_mode` | e.g. `Wide`, `Zone`, `Flexible Spot: M`, `Tracking: Expand Flexible Spot` … |
  | `af_tracking`, `face_eye` | any subject/face/eye detection info the camera records, if decodable |
  | `overview`, `crop` | absolute paths of written JPEGs (`render` only) |
  | `source` | `provided`, `embedded_preview`, `image` (`render` only) |
  | `source_width`, `source_height` | dimensions of the image the crop was taken from |

  `--format json` (default): same data as a JSON object (for humans/debugging).
* Exit code 0 for `ok` and `no_focus` and `unsupported`; 1 for `error`.
  Always print the kv/json block, even on error.

### Sony maker note facts (verify against ExifTool's `lib/Image/ExifTool/Sony.pm`)

* Maker note lives in Exif IFD tag 0x927c; Sony maker notes are a plain TIFF
  IFD, sometimes preceded by `"SONY DSC \0\0\0"` / `"SONY CAM \0\0\0"` (12 bytes);
  offsets are relative to the main TIFF header.
* `0x2027 FocusLocation` int16u[4] = image width, height, focus x, focus y.
* `0x204a FocusLocation2` (newer bodies, incl. a7 IV?) — check semantics.
* `0x2037 FocusFrameSize` int16u[3] = width, height, valid flag.
* `0x201b FocusMode`, `0x201c AFAreaModeSetting`, `0x201d FlexibleSpotPosition`,
  `0x2020 AFPointsUsed`, `0x2021 AFTracking`, plus enciphered `0x9400`/`0x940c`
  blocks — decode what is cheap and reliable, don't go down rabbit holes.
* If FocusLocation is `0 0` or absent (e.g. MF), report `no_focus`.

## Lightroom plugin

* `Info.lua`: SDK version 10+ (min 6.0), identifier `dev.focuspoint.lightroom`,
  name "Focus Point".
* **Primary UI — floating viewer** (`LrDialogs.presentFloatingDialog`): Library
  menu → *Plug-in Extras* → "Focus Point Viewer…". Stays open while the user
  culls normally with the keyboard; it follows the active photo
  (`selectionChangeObserver` and/or a polling `LrTasks` loop on
  `catalog:getTargetPhoto()`), re-renders asynchronously, and shows: overview
  image, zoomed crop, text line (focus mode · AF area · tracking/eye info ·
  file name), and buttons Pick / Reject / Unflag (catalog write access).
* Also: "Show Focus Point" (one-off modal for the selected photo) and
  "Read Focus Metadata for Selected Photos" which fills plugin metadata fields
  (`focusMode`, `afAreaMode`, `focusPoint` ("x, y" as percentages),
  `afTracking`) shown in the Metadata panel and searchable/browsable in the
  Library filter (via `metadataProvider`, `metadataTagsetFactory` optional).
* Image source: when the photo has no Develop crop (`photo:getDevelopSettings()`
  `HasCrop` false/nil) and isn't a virtual copy with crop, request a large
  Lightroom preview with `photo:requestJpegThumbnail(2560, 2560, cb)`, write the
  bytes to a temp file and pass it as `--source`; if its aspect doesn't match
  the expected displayed aspect (user rotated 90°), or anything fails, omit
  `--source` (CLI falls back to the embedded preview). Keep the
  thumbnail request object referenced until the callback fires.
* Run the CLI with `LrTasks.execute`, redirecting stdout to a temp file, quoting
  paths safely (single quotes on macOS, escape embedded `'`). Binary path:
  `_PLUGIN.path .. "/bin/focuspoint"`. Temp/output dir under
  `LrPathUtils.getStandardFilePath("temp")/focuspoint/`; clean old renders.
* Non-Sony / no-focus photos: show a clear message, not an error dialog.
* Log via `LrLogger` (`focuspoint`, logfile).
