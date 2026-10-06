## Lightroom plug-in

### Install

```sh
nix run .#install
```

This builds the CLI, bundles it into `focuspoint.lrplugin/bin/focuspoint` and
copies the plug-in (real files, not a symlink) to
`~/Library/Application Support/Adobe/Lightroom/Modules/focuspoint.lrplugin`.
Lightroom Classic loads everything in that `Modules` folder automatically when
it starts, so just restart Lightroom (or use **File › Plug-in Manager… › Reload
Plug-in** if it is already listed).

Alternatively build it with `nix build` and add `result/focuspoint.lrplugin`
in **File › Plug-in Manager… › Add**. The Nix store copy is read-only, which
is fine for running it; copy it somewhere writable if you prefer.

The Plug-in Manager entry for *Focus Point* shows where the helper binary is
expected, whether it was found, its version and where the log file is.

The first time Lightroom loads the plug-in it may ask to update the catalog
for the plug-in's custom metadata fields. That is expected.

### Usage

All commands are under **Library › Plug-in Extras** and also under
**File › Plug-in Extras** (so they work from Develop too):

* **Focus Point Viewer…** opens a floating window that stays open while you
  cull. It follows the active photo, so arrow keys, the filmstrip and Develop
  all work as usual. It shows:
  * the whole frame with the camera's focus box (green, dark outline) and a
    small crosshair,
  * a 1:1 crop around the focus point, so you can judge sharpness,
  * focus mode · AF area · tracking/face/eye info · file name, and the
    current flag,
  * **Pick**, **Reject** and **Unflag** buttons. They act on the photo shown
    in the window, then show its new flag.
  * **Use Lightroom preview** (on by default, remembered): for uncropped
    photos the overview comes from Lightroom's own preview, so it has your
    edits. Cropped, straightened or transformed photos, and photos rotated in
    Lightroom, always use the JPEG embedded in the raw file, because the focus
    coordinates refer to the camera's full frame. **Re-render** redraws the
    current photo, for example after you change its crop.

  If you hold an arrow key, the viewer waits until you stop and then renders
  only the photo you landed on. Choosing the menu item again brings the open
  window to the front.
* **Show Focus Point** shows the same thing for the selected photo in a
  larger dialog that you close when you're done.
* **Read Focus Metadata for Selected Photos** reads the focus data of every
  selected photo and saves it in the catalog. The fields are *Focus Mode*,
  *AF Area Mode*, *Focus Point* (x%, y% of the frame), *AF Tracking* and
  *Focus Data* (`ok` / `no focus` / `unsupported`). They show up in the
  Metadata panel: pick the **Focus Point** tagset, or *All Plug-in Metadata*.
  You can search them with the Library Filter's **Text** filter and in smart
  collections. Every field except *Focus Point* can also be chosen as a column
  in the **Metadata** filter, so you can, for example, list all manual-focus
  shots or every photo taken with *Tracking: Wide*.

Photos that aren't from a supported Sony body, manual-focus shots, videos and
photos whose original file is offline get a short explanation instead of an
error.

### Tips

* **Build 1:1 previews** (Library › Previews › Build 1:1 Previews, or choose
  1:1 on import) so Lightroom doesn't have to render a preview before the
  viewer can use it. That makes switching photos faster.
* **Keyboard shortcut for the viewer:** macOS can give any menu item a
  shortcut. Open *System Settings › Keyboard › Keyboard Shortcuts… › App
  Shortcuts*, click **+**, choose *Adobe Lightroom Classic*, and type the
  menu title exactly: `Focus Point Viewer…`. The last character is the
  single ellipsis character (type it with **⌥ ;**), not three dots. Then pick
  a shortcut that Lightroom doesn't use, such as **⌃⌥F**.
* After you click a button in the viewer, the viewer has keyboard focus.
  Click back on the grid, loupe or filmstrip before you use the arrow keys or
  P/X/U again.
* The viewer remembers where you put it.

### Troubleshooting

* **"The focuspoint helper program is missing" or "not executable"**: run
  `nix run .#install` again, then reload the plug-in. The binary must be at
  `focuspoint.lrplugin/bin/focuspoint` and be executable
  (`chmod +x …/bin/focuspoint`). If you copied the plug-in from another
  machine, macOS may have quarantined it:
  `xattr -dr com.apple.quarantine ~/Library/Application\ Support/Adobe/Lightroom/Modules/focuspoint.lrplugin`.
* **Log file:** the plug-in logs every CLI call and every decision, such as
  why it didn't use the Lightroom preview, to `focuspoint.log`:
  * Lightroom Classic 14 and later:
    `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/focuspoint.log`
    (Windows: `%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\`)
  * earlier versions: `~/Documents/LrClassicLogs/focuspoint.log`
* **The box is in the wrong place:** turn off *Use Lightroom preview* and
  click *Re-render*. If the box is then correct, the Lightroom preview didn't
  match the camera frame. This can happen with photos rotated 180° in
  Lightroom, or with strong lens-distortion corrections. Please report it with
  the log lines for that photo.
* You can run the CLI by hand to see exactly what it reads:
  `…/focuspoint.lrplugin/bin/focuspoint info photo.ARW`.
* Temporary files live in `$TMPDIR/focuspoint/`. Rendered images are deleted
  when they are replaced or the window closes. Leftovers older than 10 minutes
  are removed the next time a window opens. You can also delete the folder
  yourself at any time while Lightroom isn't showing a Focus Point window.
