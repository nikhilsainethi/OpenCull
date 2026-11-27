# OpenCull

**Free, private, on-device photo culling for macOS.** OpenCull looks through a folder of
shoot photos, groups bursts and near-duplicates, flags blurry shots, closed eyes and bad
exposure, picks the best frame of each group, and lets you confirm everything with the
keyboard. It then writes your picks and ratings to XMP sidecars for Lightroom Classic,
Bridge or Capture One, or copies your picks to a folder.

- **100% local.** No account, no internet connection, no API keys, no uploads.
- **No model downloads.** It uses the computer-vision models built into macOS (Apple Vision).
- **Your originals are never modified.** Results go into XMP sidecar files or copies.
- **Open source** (MIT).

> OpenCull is an independent project. It is not affiliated with, and contains no code
> from, Aftershoot or any other culling product.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- macOS 15 or later adds Apple's aesthetics score to the ranking. On macOS 14 everything
  else works and that part of the score is neutral.

## Install

### Download

1. Download `OpenCull-x.y.z-macOS.zip` from the [Releases](../../releases) page and unzip it.
2. Move `OpenCull.app` to Applications.
3. First launch: release builds are not notarized by Apple, so macOS will block a normal
   double-click. Right-click (or Control-click) the app → **Open** → **Open**. On recent
   macOS versions you may instead need **System Settings → Privacy & Security → Open Anyway**.

### Build from source

Needs Xcode 15.3 or later (or the matching Command Line Tools).

```bash
git clone https://github.com/nikhilsainethi/OpenCull.git
cd OpenCull
./scripts/build-app.sh        # creates dist/OpenCull.app and a release zip
open dist/OpenCull.app
```

For development: `swift run OpenCull`, or open `Package.swift` in Xcode.

## How to cull

1. **Open Folder…** (⌘O) or drop a folder on the window. Only that folder is scanned, not
   subfolders. A RAW and JPEG with the same name (e.g. `IMG_0001.CR3` + `IMG_0001.JPG`)
   count as one photo.
2. Analysis starts right away and runs in the background. You can start reviewing straight
   away; results fill in as they're ready.
3. Review with the keyboard:

   | Key | Action |
   |---|---|
   | ← → | previous / next photo |
   | ↑ ↓ | previous / next group |
   | P | pick |
   | X | reject |
   | U | clear the decision |
   | 1–5 / 0 | star rating / remove rating |
   | F | show face boxes (green = eyes open, red = closed) |

   By default, the next photo is selected after P or X (you can turn this off in Settings).

4. Optional: **Accept Suggestions** (⇧⌘A) applies OpenCull's suggested pick/reject to every
   photo you haven't decided yet. You can still change any of them.
5. **Export**:
   - **Write XMP Sidecars** (⇧⌘S) creates `IMG_0001.xmp` next to each decided or rated photo.
   - **Copy Picks to Folder…** (⇧⌘E) copies picked photos, their RAW/JPEG companions and
     sidecars to a folder you choose. Existing files there are never overwritten.

Decisions are saved automatically, so you can close the app and continue later. Analysis
results are cached so reopening a folder is instant. Both are stored in
`~/Library/Application Support/OpenCull/`.

### What gets written to XMP

| Your decision | `xmp:Rating` | `xmp:Label` |
|---|---|---|
| Pick | your stars, minimum 1 | Green |
| Reject | -1 (Adobe's "rejected" value) | Red |
| Undecided with stars | your stars | unchanged |
| Undecided, no stars | nothing written | nothing written |

- If a sidecar already exists (for example with Lightroom edits), OpenCull changes only the
  rating and label, keeps everything else, and saves the original once as
  `IMG_0001.xmp.opencull-backup`. Sidecars with a layout it doesn't recognize are skipped
  and reported.
- **Lightroom Classic:** for photos already in your catalog, select them and choose
  **Metadata → Read Metadata from Files**. New imports read the sidecars automatically.
  Lightroom keeps its own pick/reject flags in the catalog only, so filter rejects by the
  **Red** label. The color label names must match your active label set (the default set
  uses Red and Green).
- **JPEG, TIFF, PNG and DNG:** Lightroom expects metadata inside these files rather than in
  sidecars, so for these formats use **Copy Picks to Folder** instead.

## How it works

Everything runs on your Mac, using standard Apple frameworks.

```text
folder ─► scan & pair RAW+JPEG ─► decode preview ─► measure ─► group ─► score ─► suggest ─► you decide ─► export
```

1. **Fast decoding.** RAW files embed a full-size JPEG preview from the camera. OpenCull
   reads that through ImageIO instead of decoding the RAW, and only falls back to a full
   RAW decode when the preview is missing or tiny. Analysis uses a 1600-pixel version.
2. **Sharpness.** The image is split into tiles and the *variance of the Laplacian* (how
   much fine edge detail each tile has) is measured. The average of the sharpest 5% of
   tiles is used, so a sharp subject on a deliberately blurred background still counts as
   sharp. When there's a face, the largest face's own sharpness is used.
3. **Faces & eyes.** Apple Vision finds faces and eye outlines. Eye openness is the eye's
   height divided by its width, measured along the eye's own axis so head tilt doesn't
   matter. The more-open eye is used, so profile shots don't cause false alarms. Faces
   narrower than 5% of the frame are ignored for these checks. Vision's face capture
   quality score helps choose between frames of the same person.
4. **Exposure.** Mean brightness plus the fraction of pure-white and pure-black pixels.
5. **Aesthetics** (macOS 15+). Apple Vision's overall aesthetics score.
6. **Grouping.** Photos are ordered by capture time (EXIF, including sub-seconds). A
   photo joins the previous one's group when it was taken within 3 seconds and looks
   alike, either to Vision's image feature print or to a blur-tolerant low-resolution
   layout signature. The second check matters because a badly blurred frame no longer
   "looks alike" to the neural feature print, yet it still belongs to the burst.
7. **Scoring.** 0–100, weighted: 40% sharpness (half relative to the group's sharpest
   frame), 20% face quality, 25% aesthetics, 15% exposure, minus penalties for closed
   eyes and blur. The highest score in a group is crowned **Best**.
8. **Suggestions.** Blurry or closed-eye shots are suggested as rejects. In a group, every
   frame except the best is suggested as a reject (you can turn this off). Everything else
   is suggested as a pick. Filled badges show *your* decision; outlined badges are only
   suggestions.

All thresholds can be adjusted under **OpenCull → Settings** (⌘,).

## Accuracy: please read

- The detection rules are documented heuristics, not a model trained on photographers'
  choices. They're good at catching **technical** problems (missed focus, blinks, burst
  duplicates). They **don't know your taste**. Always review suggestions before deleting
  anything; OpenCull itself never deletes files.
- Default thresholds were checked on a small set of test images (eyes open ≈ 0.24–0.32,
  closed ≈ 0.03–0.04; same-scene similarity ≈ 0.95+, different scenes ≈ 0.6–0.7). Your
  camera, lenses and style may need different values. Use Settings, or run the
  command-line tool below to see the raw numbers.
- Noisy high-ISO images can look "sharper" than they are, because noise adds fine detail.
- Faces that are very small, heavily turned away, or covered (sunglasses, masks) may not be
  detected, so their eyes aren't checked.

## Command-line tool

```bash
swift run opencull-cli ~/Pictures/Shoot            # table
swift run opencull-cli ~/Pictures/Shoot --json     # every measurement as JSON
```

`SimPrev` shows the Vision/layout similarity to the previous row, which helps when tuning
the grouping settings. A release build is included in `dist/` after running the build script.

To launch the app with a folder already open:
`open -a OpenCull --args --open ~/Pictures/Shoot`.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/CullCore` | Decoding, analysis, grouping, scoring, XMP and session storage (no UI) |
| `Sources/OpenCull` | SwiftUI macOS app |
| `Sources/OpenCullCLI` | Command-line tool |
| `Tests/CullCoreTests` | Unit tests (`swift test`) |
| `scripts/build-app.sh` | Builds a universal `.app` and release zip |

## Roadmap ideas

- Learn your personal taste from your pick/reject history (small on-device model)
- Optional open-weight CLIP model (Core ML) for stronger similarity and text search
  ("first dance", "bride")
- Side-by-side comparison of a whole group, zoom to 100% on faces
- Subfolder scanning, Photos library support

Contributions are welcome. Please run `swift test` before opening a pull request.

## Distributing signed builds (maintainers)

To avoid the Gatekeeper warning, sign with a Developer ID Application certificate (paid
Apple Developer Program) and notarize:

```bash
codesign --force --options runtime --sign "Developer ID Application: NAME (TEAMID)" dist/OpenCull.app
ditto -c -k --keepParent dist/OpenCull.app OpenCull.zip
xcrun notarytool submit OpenCull.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/OpenCull.app
```

## License

MIT. See [LICENSE](LICENSE).
