# Multi-source local import and contextual people culling

Approved by the user on November 27, 2026. Build the proposed native workflow and merge all completed work into main after verification.

## Product contract

One macOS review/edit/export workspace accepts camera folders, individual and multiple image files, Apple Photos selections and promised-file drops, and files/ZIPs downloaded from Google Photos or Google Takeout. No external service APIs, OAuth, cloud inference, account scraping, or uploads. The Google Photos action opens its official website in the user's browser; importing the downloaded originals is an explicit local handoff. Cloud originals require internet to obtain; analysis and editing work offline afterward. The app must never claim a thumbnail or arbitrary website link is an original.

Imports copy sources into a managed album and retain original names, provenance, and available capture metadata. Full-resolution availability is described honestly. Existing culling, editing, export, and source-preservation behavior remains available. Picker representations are labeled as such; no source-library writeback or whole-library access is implied.

People assessment stores separate eye measurements, measurement confidence, head orientation, and a conservative camera-attention estimate. Shooting intent distinguishes general, posed portraits/groups, candid photography, and creative blur. Head pose is not eye gaze. Unavailable/occluded/small-face measurements remain unknown. An uncertain wink, gaze estimate, or creative blur requires review rather than automatic rejection. Group recommendations consider all significant faces, without a cross-library identity database. Subject/face focus is evaluated separately from background softness.

## Architecture

- A pure CullCore import service validates and stages local inputs, safely extracts bounded ZIP archives using system zlib, preserves directory/pair relationships and Takeout sidecar metadata, and writes an import manifest. It never overwrites sources or existing imports.
- An AppKit drop receiver accepts file promises before file URLs, receives them asynchronously, and reports actual files to the same import service. Remote links are rejected with a download instruction rather than fetched.
- LibraryModel owns import busy/cancel/state transitions; ContentView exposes source actions and provenance, and the Photos picker feeds selected image data through the managed path. Import failure preserves the current album.
- CullCore face/intent assessment extends current analysis and scoring. The analysis cache version is bumped. The UI displays per-face reasons and intent controls with confidence/unknown states.

## Validation and delivery

Use red/green regressions for ZIP traversal/symlinks/bombs/truncation, corrupt images, collisions, cancellation, bundle pairing, metadata, face confidence, one-eye closure, head-pose versus gaze, candid/creative policy, and group selection. Run the full suite, adversarial CLI cases, universal packaging/signature checks, native import/review/export checks when the Mac is accessible, and independent reviews. Retain explicit limits on unlabeled real-shoot accuracy, provider representations, system drag automation, and cloud-library writeback. Push the finished branch, wait for CI, merge PR #1 using its verified head SHA, then verify main and deliver the matching build/source/report.
