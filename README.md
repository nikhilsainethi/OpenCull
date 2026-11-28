# OpenCull 0.4

**Native photo culling, comparison and nondestructive editing for macOS.** Open a
shoot, review technical suggestions, compare frames at full resolution, develop
selections and export finished copies. General-photography defaults are included.

**[⬇ Download OpenCull 0.4.0 for macOS (.dmg)](https://github.com/nikhilsainethi/OpenCull/releases/download/v0.4.0/OpenCull-0.4.0-macOS.dmg)**

For Apple Silicon and Intel Macs running macOS 14 or later.

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

Open the downloaded DMG and drag **OpenCull** onto **Applications**. This release
uses ad-hoc signing. If macOS blocks the first launch, open **System Settings →
Privacy & Security → Open Anyway**. The app ZIP and command-line tool are also
available on the [Releases page](https://github.com/nikhilsainethi/OpenCull/releases).

```bash
git clone https://github.com/nikhilsainethi/OpenCull.git
cd OpenCull
swift test
./scripts/build-app.sh
./scripts/verify-release.sh
open dist/OpenCull.app
```

Packaging creates a universal app, a drag-to-install DMG, an app ZIP and the CLI in
`dist/`, after staging and verification in a fresh system temporary directory. The
verification mounts the DMG read-only and checks it holds the same signed universal
app plus an Applications link. Packaging never installs an app or publishes a release.
Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which tests, builds,
verifies and publishes the DMG, ZIP and CLI as a GitHub Release. Previous generated outputs are preserved in `dist/.previous/`;
unrelated `dist/` files are untouched. To change the numeric version, use
`VERSION=0.4.1 ./scripts/build-app.sh` and `VERSION=0.4.1 ./scripts/verify-release.sh`.
For development, use `swift run OpenCull` or open `Package.swift` in Xcode.

## Import an album

Use **Open Folder…** (⌘O) to work in place, or reopen a recent album from
**Albums**. Enable **Include subfolders** to scan a folder tree. A single matching
RAW/JPEG pair is combined when unambiguous; independent same-stem formats remain
separately reviewable.

**Import** copies files, multiple folders or ZIP archives into a managed local
album. Drag local files/folders/ZIPs onto the window; native file promises from
Photos are supported when the source supplies them. Original filenames, folder
relationships and RAW/JPEG/XMP companions are retained. ZIP expansion is bounded
and rejects unsafe paths, links, encryption, malformed archives and unsupported
ZIP64. The default import limits are 20,000 entries, 2 GiB expanded in total and
512 MiB per file; archive paths are limited to 1024 UTF-8 bytes and 64 levels.
Split larger exports into smaller albums. Imports stage and publish a complete new album; cancelling or failing an
import preserves the current album. Source information is stored locally beside
the imported copies and displayed in the inspector.

**Apple Photos** uses the system picker with the current representation requested.
Only chosen items are copied; available asset identifiers are retained locally. When the picker does not expose
a source filename, copies receive `Photo_00001`-style names.
The supplied representation can be rendered or converted, so original/RAW quality
is explicitly unverified. iCloud items may need internet before import. This is
not a Photos library browser and does not write decisions back to Photos.

**Google Photos** opens the official website in your browser. Select photos there,
use **Download**, then **Import downloads…**; larger libraries can use **Import
Takeout…** for ZIPs or extracted folders. Takeout JSON capture times supply missing
EXIF capture dates without modifying photo bytes. This handoff stores no Google
sign-in, uses no Google service API and does not scrape private web endpoints.
Website links, `blob:` URLs and browser thumbnails are not original photo files;
download the desired files first. There is no continuous Google library sync or
cloud-library writeback. Downloading needs internet; culling and editing run on
your Mac after files arrive.

Analysis runs in the background; decode errors and partial Vision results are
visible. Album actions includes **Retry failed analysis**.

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

### People and photographic intent

Choose **Shooting intent** in the album bar or Settings. General photography is
the default. Posed portrait and posed group modes require review when camera
attention is uncertain; candid/documentary treats looking away as neutral.
Creative mode treats soft focus as potentially intentional and requests review
instead of automatically rejecting blur.

Eye checks keep separate left/right landmark measurements. Clear supported
both-eye closure can flag a blink; a possible wink or one-eye closure stays for
review. Profiles, occlusion, low landmark support and small faces produce unknown
states. Head pose is shown separately from a conservative pupil-position estimate
of camera attention: head direction alone is not gaze. The **People** disclosure
explains each detected face. These local geometric heuristics are not calibrated
gaze tracking, biometric identification or a trained blink model. Uncertain frames
cannot become automatic group winners or target-count picks. Face-region focus
protects supported portraits from background bokeh, but the app does not have
universal subject segmentation or a proven intentional-blur classifier.

### Best available for group portraits

Choose **Posed group** in the shooting intent menu and open **Best available**
on a group of similar photos. If an automatic grouping misses part of a burst,
select its photos and use the album action to merge them. OpenCull compares the
two leading original frames, explains the difference, and shows the face regions
side by side. You can inspect other faces and pick either frame. A close call or
a conflict with the ordinary culling suggestion leaves the finalists for review.

Face correspondence uses positions within this burst and checks the color below
each face to flag an unlikely match. Missing detections, uncertain gaze and
ambiguous matches are shown for inspection. Crops use the original composition.
For preview-only RAW files, the comparison labels the embedded preview or the
companion photo it displays. The feature works offline and makes no face identity
records. When you reopen a shoot from an
older version, OpenCull refreshes its analysis and retains your saved decisions.

### Keyboard

Single keys apply during photo review, not text entry.

| Key | Action |
|---|---|
| Hold Space / ⌘K | Aperture menu (see below) |
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

### Aperture menu

The aperture menu is a camera-lens iris whose six blades are commands. It only
appears when you invoke it, at the mouse pointer:

- **Hold Space**, point toward a blade and release to run it. Releasing in the lens
  opening leaves the menu open.
- **⌘K** (or **View → Aperture Menu**) opens it for clicking. Arrow keys move around
  the iris, Return runs the highlighted blade and **1–6** run a blade directly.
- **Esc** goes back or closes; clicking outside the lens closes it.

| Main iris | Album actions iris |
|---|---|
| 1 Import · 2 Cull · 3 Compare · 4 Edit · 5 Accept · 6 Album actions | 1 Merge group · 2 Split group · 3 Reset groups · 4 Duplicates · 5 Target picks · 6 Retry analysis |

Unavailable blades are dimmed and the lens opening explains why (for example, open an
album first). The current workspace blade has an accent edge. With **Reduce motion**
enabled, the iris appears without its opening animation. The menu does not open over
sheets, while typing in a text field, or while an import is running.

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

PNG copies preserve encoded image data, transparency and color information.
Unsupported or conflicting PNG XMP packets are reported without publishing a
partial photo bundle.

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

The CLI accepts `--intent general|posedPortrait|groupPortrait|candid|creative` and
includes eye/attention descriptions and review reasons in `--json` output. Compare
intent modes on the same folder to inspect policy differences; photographic
accuracy still needs a consented, labeled sample set of real shoots.

Source workflow references: [Google Photos downloads](https://support.google.com/photos/answer/7652919?co=GENIE.Platform%3DDesktop&hl=en), [Google Takeout](https://support.google.com/photos/answer/3024190?hl=en), and [Apple PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker).
