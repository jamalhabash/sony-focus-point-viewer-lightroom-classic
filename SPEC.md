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

`nix build .#plugin` produces `result/focuspoint.lrplugin/` = Lua sources + `bin/focuspoint`
(plain `nix build` builds just the CLI into `result/bin/focuspoint`).
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
  * Image sources (`--source <JPEG>` is assumed to be the full, uncropped
    frame already in *display* orientation — e.g. a Lightroom preview;
    embedded previews / camera JPEGs are in *sensor* orientation, so EXIF
    Orientation is applied to them before drawing/saving):
    * overview: `--source` if given (and its aspect matches), otherwise the
      smallest embedded JPEG whose long edge is >= `--size` (or the largest),
      or the JPEG file itself.
    * crop: always the highest-resolution image available — the larger (by
      pixel count) of `--source` and the largest embedded JPEG in the ARW
      (PreviewImage / JpgFromRaw; a7 IV v2 firmware embeds a full 7008x4672
      JpgFromRaw) or the JPEG file itself; embedded/file wins a tie.
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
  | `focus_mode` | ExifTool strings: `AF-C`, `AF-S`, `AF-A`, `DMF`, `Manual` |
  | `af_area_mode` | e.g. `Wide`, `Zone`, `Flexible Spot`, `Tracking: Wide`, `Human Eye Tracking: Zone` (see notes below) |
  | `af_tracking`, `face_eye` | any subject/face/eye detection info the camera records, if decodable |
  | `overview`, `crop` | absolute paths of written JPEGs (`render` only) |
  | `source` | image the **overview** was drawn from: `provided`, `embedded_preview`, `image` (`render` only) |
  | `source_width`, `source_height` | dimensions of the overview source image |
  | `crop_source` | image the **crop** was cut from: `provided`, `embedded_preview`, `image` (only when a crop is written) |
  | `crop_source_width`, `crop_source_height` | dimensions of the crop source image |

  `--format json` (default): same data as a JSON object (for humans/debugging).
* Exit code 0 for `ok` and `no_focus` and `unsupported`; 1 for `error`.
  Always print the kv/json block, even on error.
* Implementation notes / clarifications (Rust CLI, additive only):
  * `af_area_mode` = the area mode actually used (enciphered tag 0x9402, offset
    0x17, ExifTool `AFAreaMode`) combined with the menu setting (0x201c,
    ExifTool `AFAreaModeSetting`) as `"<used>: <setting>"` when they differ,
    e.g. `Tracking: Wide`, `Human Eye Tracking: Zone`; otherwise just one
    value, e.g. `Zone`, `Flexible Spot`.
  * `face_eye`: `Face`, `Human Eye` or `Animal Eye` when the camera says so
    (AFAreaMode 15/21/20, or AFTracking = Face tracking); omitted otherwise.
  * `af_tracking`: ExifTool `AFTracking` (`Off`, `Face tracking`, `Lock On AF`).
  * Extra keys that may appear: `file_type` (`tiff`/`jpeg`/`heif`),
    `software`, `af_area_mode_setting`, `af_zone` (e.g. `Center Zone`),
    `flexible_spot_position` (`"x y"`, ExifTool 640x480-ish grid), `warning`
    (render: e.g. `--source` rejected because its aspect ratio does not match
    the frame, in which case the embedded image is used instead).
  * `no_focus` (stripped maker note, non-Sony, manual focus, FocusLocation
    `0 0`): focus geometry keys are omitted; `render` still writes the
    `overview` (no box) but no `crop`.
  * `--source` whose aspect ratio differs from the expected displayed frame by
    more than 3% is ignored (falls back to the embedded image, sets `warning`).
  * HEIF: `info` works; `render` needs `--source` (no HEVC decoder), else `status=error`.
  * Crop: native 1:1 pixels from the largest available image, never upscaled;
    if that image is smaller than `--crop-size` in a dimension, the crop is
    smaller too.

### Sony maker note facts (verify against ExifTool's `lib/Image/ExifTool/Sony.pm`)

* Maker note lives in Exif IFD tag 0x927c; Sony maker notes are a plain TIFF
  IFD, sometimes preceded by `"SONY DSC \0\0\0"` / `"SONY CAM \0\0\0"` (12 bytes);
  offsets are relative to the main TIFF header.
* `0x2027 FocusLocation` int16u[4] = image width, height, focus x, focus y.
* `0x204a FocusLocation2` (ILCE-9M3 and newer; ExifTool: "same as FocusLocation
  within one pixel"). Not written by the a7 IV (v2.00 samples); used only as a
  fallback when 0x2027 is missing.
* Verified on a7 IV: `0x2037` is stored as `undef[6]` and must be read as
  int16u[3]; the focus-location space is the full output image size in sensor
  orientation (7008x4672 FF, 4608x3072 APS-C), also for S/M-size RAWs.
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

## v0.2 — instant flipping (render cache + prefetch)

Goal: flipping to a photo in the viewer shows its focus point with no
perceptible delay, even when scrubbing quickly.

### CLI additions

* `--cache-dir <DIR>` on `render`: outputs go to a persistent cache instead of
  unique per-invocation names. Cache key = hash of (canonical path, file size,
  file mtime, `--size`, `--crop-size`, a render-format version constant).
  Files: `<key>.kv` (the full kv block as printed), `<key>-overview.jpg`,
  `<key>-crop.jpg`. On a hit, print the stored kv (paths still valid) without
  decoding anything and touch the `.kv` mtime (LRU). Writes are atomic
  (temp file + rename) because the on-demand render and a batch may race on the
  same key. When `--source` is given the cache is bypassed (old behaviour).
  Paths inside a cache entry are stable, which is fine: content for a key never
  changes. Add kv key `cached=true|false`.
* New subcommand:
  ```
  focuspoint batch --cache-dir <DIR> [--list <FILE> | paths on stdin, one per line]
                   [--size PX] [--crop-size PX] [--jobs N] [--format kv|json]
                   [--cache-max-mb N (default 2048)]
  ```
  Renders every file (skipping cache hits) in parallel with N worker threads
  (default: max(2, available_parallelism/2)), memory-conscious (each worker
  holds one decoded image at a time). Prints, in INPUT order, one kv block per
  file: first line `file=<input path as given>`, then the same keys `render`
  prints, then a line `---`. Each file's failure is reported in its own block
  (`status=error`), never aborts the batch. After the batch, prune the cache to
  `--cache-max-mb` by deleting least-recently-used entries (all files of a key
  together). Exit 0 unless the arguments themselves are bad.
* Speed of a single cold `render`: measure; reduce if there are cheap wins
  (e.g. decode the full-size embedded JPEG only once, avoid re-encoding work,
  faster JPEG decoder/encoder settings, decode-to-region). Report before/after.

### Plugin changes

* Cache dir: `~/Library/Caches/focuspoint` on macOS
  (`LrPathUtils.getStandardFilePath('home') .. '/Library/Caches/focuspoint'`),
  temp dir on Windows.
* Default image source for the overview becomes the camera's embedded JPEG.
  The Lightroom-preview option stays, but under a NEW pref key so existing
  installs also get the new default (off). Label: "Use Lightroom preview for
  overview (shows edits, slower)". HEIF still uses the Lightroom preview
  automatically (it's the only renderable source).
* On-demand path: `render --cache-dir` in ONE process call (drop the separate
  `info` call when the Lightroom preview isn't used). In-memory map
  `photo.localIdentifier → parsed result`; on a target change with a hit
  whose files still exist, show it immediately (no debounce). Misses: render
  immediately; keep only a very short debounce (~80 ms) for misses; poll every
  ~50 ms.
* Prefetch task (separate `LrTasks` task, runs while the viewer is open and
  the Lightroom-preview option is off): the photo list is
  `catalog:getMultipleSelectedOrAllPhotos()` (filmstrip order assumed —
  verify), paths via `catalog:batchGetRawMetadata`. Order candidates by
  distance from the current target, forward first (+1, −1, +2, −2 …, with a
  forward bias), skip videos/missing/known-cached/unsupported, and render them
  in batches of ~12 via `focuspoint batch`. Re-plan after every batch (the user
  has moved). Refresh the photo list when the target changes or every few
  seconds. Cap: at most ~1000 photos around the target. Stop when the viewer
  closes. Feed results into the same in-memory map so flips become hits.
* Status line shows `cached` vs render time for the current photo, and a
  small prefetch progress note (e.g. "pre-rendered 142/388").
* Also let the one-off modal and "Read Focus Metadata" reuse the cache.
