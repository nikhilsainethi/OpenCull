# OpenCull 0.2

**Native photo culling, comparison and nondestructive editing for macOS.** Open a
shoot, review technical suggestions, compare frames at full resolution, develop
selections and export finished copies. General-photography defaults are included.

- **On your Mac:** analysis, preference adaptation, edits and rendering use Apple
  frameworks locally. No OpenCull account, API key or cloud AI service.
- **Originals stay intact:** adjustments live in recipes. Exports create new files;
  explicit XMP synchronization updates sidecars with recoverable backups.
- **Native:** SwiftUI/AppKit, ImageIO, Core Image, Vision and the system Photos
  picker. No app-specific model download or third-party runtime dependency.
- **Open source:** MIT.

OpenCull is independent of Aftershoot and does not claim identical models,
features or accuracy. Its local preference model is a small ranking aid, not an
imitation of a proprietary editing or culling model.

## Requirements and installation

- **Run:** macOS 14 Sonoma or newer; Apple Silicon or Intel. macOS 15+ adds Apple's
  aesthetics measurement. RAW compatibility depends on installed macOS decoders.
- **Build:** Xcode 16+ or equivalent Command Line Tools with a macOS 15+ SDK.
  A newer SDK can build the macOS 14 deployment target.

When an asset is published, download `OpenCull-0.2.0-macOS.zip` from
[Releases](https://github.com/nikhilsainethi/OpenCull/releases), unzip it and move
it to Applications yourself. Builds are ad-hoc signed, **not notarized**. macOS
may require Control-click → Open or Privacy & Security → Open Anyway.

```bash
git clone https://github.com/nikhilsainethi/OpenCull.git
cd OpenCull
swift test
./scripts/build-app.sh
./scripts/verify-release.sh
open dist/OpenCull.app
```

Packaging creates a universal app, CLI and app ZIP in `dist/`, after staging and
verification in a fresh system temporary directory. It never installs an app or
publishes a release. Previous generated outputs are preserved in `dist/.previous/`;
unrelated `dist/` files are untouched. To change the numeric version, use
`VERSION=0.2.1 ./scripts/build-app.sh` and `VERSION=0.2.1 ./scripts/verify-release.sh`.
For development, use `swift run OpenCull` or open `Package.swift` in Xcode.

## Import an album

Use **Open Folder…** (⌘O), drop a folder on the window, or reopen a recent album
from **Albums**. Enable **Include subfolders** before opening to scan a folder
tree. A single matching RAW/JPEG pair is combined when unambiguous; independent
same-stem formats remain separately reviewable.

**Photos** opens Apple's picker. Selected representations are copied into a local
OpenCull album without changing the Photos library. The system may need to
retrieve selected iCloud items before import. Analysis runs in the background;
decode errors and partial Vision results are visible. Album actions includes
**Retry failed analysis**.

## Cull and compare

Outlined badges are suggestions; filled badges are your decisions. **Needs review**
shows ambiguous, incomplete or unsupported results. **Accept** waits for analysis
and leaves uncertain photos undecided; the complete operation is undoable.

- Click to select. **⌘-click or ⇧-click** toggles additional individual selections;
  **⌘A** selects all visible photos. Decisions and ratings apply to selected
  photos. Auto-advance applies to a single photo.
- Select two to four photos and enter **Compare** (N), or right-click a thumbnail
  and choose **Compare this group**. Fit/100%/Face controls are shared; viewports
  pan independently. Picking a frame preserves the comparison selection.
- **100%** maps one image pixel to one physical display pixel, including Retina.
  Drag or scroll to pan. **Face** centers the chosen or largest detected face.
  The focus-subject menu can choose another person. Face boxes are hidden after
  crop/rotation, with an explanatory hint.
- Search filenames and local Vision subject/scene keywords. This is keyword
  search, not unrestricted natural-language retrieval or an installed CLIP model.
- Album actions can merge/split groups, reset manual grouping, or find byte-exact
  duplicates across the album beyond the burst time window. Different encodings
  of the same-looking image are not byte-exact duplicates.
- Set a target count, choose **Suggest target selection**, review and accept.
  Existing manual choices are retained.

### Keyboard

Single keys apply during photo review, not text entry.

| Key | Action |
|---|---|
| ← / → | Previous / next photo |
| ↑ / ↓ | Previous / next logical group |
| P / X / U | Pick / reject / clear selected decisions |
| 1–5 / 0 | Stars / remove stars |
| F | Toggle face boxes |
| B | Before / after without changing edits |
| Z | Toggle Fit / 100% |
| N / E | Compare / Edit workspace |
| ⌘A | Select all visible |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘S | Flush pending workspace saves |
| ⇧⌘A | Accept completed, review-ready suggestions |
| ⇧⌘S | Synchronize XMP beside originals |
| ⇧⌘E | Copy picked originals with current metadata |
| ⌘, | Settings |

## Develop photographs

Enter **Edit** (E). A persisted recipe drives preview and export through the same
Core Image pipeline:

- Exposure, contrast, highlight recovery and shadow lift.
- White-balance temperature/tint, saturation and vibrance.
- Luminance sharpening and noise reduction.
- Quarter-turn rotation, precise straightening, normalized crop controls and
  square/3:2/4:3/16:9 crops. Straightening trims empty edges.
- RGB histogram, original/edited toggle and reset with undo.

**Auto Tone** derives a tonal starting point from the image histogram; it does not
learn a style. Presets include Original, Natural, Vivid, Soft Portrait, Landscape
and Black & White. Save reusable local styles from current adjustments. Styles
and batch application include crop/rotation, so review compositions across frames.
A fixed saved style repeats a recipe. **Learn Adaptive Profile…** instead trains
a small local ridge-regression model from at least six selected, explicitly edited
photos with varied brightness. It relates brightness, clipping, face context and
aesthetics to your light/color/detail adjustments, then predicts a separate recipe
for each photograph. Adaptive application preserves each photo's crop/rotation.
It stores coefficients, not image pixels, and needs no pretrained model download.
This is a lightweight statistical baseline: a few example edits do not establish
professional accuracy or Aftershoot-equivalent style matching. Far outside the
training conditions, predictions shrink toward the profile's average adjustments.

**Apply to Selected Photos** or **Apply to All Picks** propagates the current
recipe as one undoable batch operation.

## Export

**Export…** offers JPEG/PNG/TIFF, all picks or selected photos, full resolution or
a smaller long edge, and JPEG quality. Outputs are upright 8-bit sRGB copies.
Rendering uses source pixels and Apple's RAW decoder when available. If an
unsupported RAW has a usable companion, export reports the companion fallback.
The renderer rejects images above 32,768 pixels per side or 150 megapixels.

Choose whether to preserve camera/location/descriptive metadata or remove it.
Current picks and stars are embedded in supported rendered outputs. Names use
`-edited` plus a numbered suffix on collision. Encoded files are staged and
atomically published; existing files and symlinks are never overwritten.

**Originals & metadata** provides two separate handoffs:

1. **Copy picked originals with current ratings…** copies original bundles and
   companions with current metadata. Any name collision skips the whole bundle;
   partial failures roll back newly created members. Supported standard-format
   copies receive embedded ratings. Unsupported embedding is reported; rendered
   JPEG/PNG/TIFF is the supported embedded-metadata handoff alternative.
2. **Synchronize XMP beside originals** preserves other valid metadata and makes
   a one-time `.xmp.opencull-backup` before changing an existing sidecar. Clearing
   a previously synchronized choice synchronizes that clear. Unsafe/unsupported
   XML is reported. Independent photos sharing an XMP basename are reported as
   ambiguous; rendered copies preserve their separate choices.

| Choice | XMP rating | XMP label |
|---|---|---|
| Pick | Your stars, minimum 1 | Green |
| Reject | -1 | Red |
| Undecided with stars | Your stars | Existing label retained |
| Previously exported, then cleared | Exported decision fields cleared | Unrelated metadata retained |

Lightroom Classic, Bridge and Capture One have their own metadata/catalog rules.
For existing Lightroom catalog entries, reading metadata from files is an explicit
editor action. Lightroom pick flags differ from XMP ratings/color labels. Verify
a sample with your editor and label set; external-editor interoperability is not
certified.

## Local storage and personalization

Choices, recipes, manual groups, recent albums, styles and caches live under
`~/Library/Application Support/OpenCull/`. Source versions and companions are
part of cache identity; replaced files do not silently reuse older previews or
choices. The bottom bar shows save status and allows retry. Orderly close flushes
saves; a failed save blocks closing. Malformed documents are preserved for recovery
and errors are reported.

Optional **Personal ranking** learns from explicit local picks, rejects and stars.
It stays neutral until 12 examples include at least four picks and four rejects.
A bounded feature-centroid model then adjusts ranking by at most ten points;
technical safeguards still apply. Reset it in Settings. It does not infer artistic
intent or identify important people. Personal ranking affects culling; adaptive
editing profiles are trained separately from edited examples as described above.

## Culling behavior and limits

Vision provides landmarks, face quality, classifications, feature prints and,
on newer macOS, aesthetics. Deterministic checks measure multiscale focus, noise,
brightness/clipping and eye openness. Grouping checks a representative and adjacent
frames to reduce chain drift. Optional layout rescue has an exposed semantic floor
and adjustable thresholds. Exposure and duplicate-rejection policies are adjustable.

These are conservative technical suggestions, not an autonomous photographer.
Intentional blur, high ISO, small/occluded faces, unusual light and expressions
can still confuse them. Noise safeguards reduce known failure modes, not prove
population accuracy. Scores are relative ranking signals, not probabilities.
OpenCull never deletes source photographs.

## CLI and verification

```bash
swift run opencull-cli ~/Pictures/Shoot
swift run opencull-cli ~/Pictures/Shoot --recursive --json
open dist/OpenCull.app --args --open ~/Pictures/Shoot
```

The CLI reports measurements, classifications, warnings and review status. Exit
codes: 0 completed analysis; 1 invalid/unreadable input; 2 missing arguments;
3 at least one photo could not be analyzed. JSON retains per-photo failures.
Invalid recursive paths are errors.

```bash
swift test
swift build --scratch-path /tmp/OpenCull-TSan --sanitize thread --product opencull-cli
./scripts/build-app.sh
./scripts/verify-release.sh
```

Tests cover metadata/RDF preservation, collision-safe export, source identity,
grouping/focus safeguards, preference adaptation, real edit pixels/formats,
physical-pixel viewport geometry, history and save workflows. CI runs build,
tests and universal packaging/verification. A universal binary does not establish
execution on every Intel Mac, camera or supported OS. No human accuracy rate or
randomized Aftershoot benchmark is claimed.

| Path | Purpose |
|---|---|
| `Sources/CullCore` | Analysis, grouping, preferences, editing, metadata and storage |
| `Sources/OpenCull` | Native workspace, history, import/export and persistence |
| `Sources/OpenCullCLI` | Folder-analysis CLI |
| `Tests/CullCoreTests`, `Tests/OpenCullTests` | Core and workspace tests |
| `scripts/build-app.sh`, `scripts/verify-release.sh` | Staged universal release verification |

## Signing for public distribution

Local packaging uses an ad-hoc signature. A maintainer can separately sign,
notarize and staple using their own Developer ID and notary profile. Packaging
does not upload anything or modify an installed application. For example:

```bash
codesign --force --options runtime --sign "Developer ID Application: NAME (TEAMID)" dist/OpenCull.app
ditto -c -k --keepParent dist/OpenCull.app OpenCull-notarize.zip
xcrun notarytool submit OpenCull-notarize.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple dist/OpenCull.app
```

## License

MIT. See [LICENSE](LICENSE).
