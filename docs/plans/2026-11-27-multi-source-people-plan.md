# Multi-source import and people culling implementation plan

> Execute with superpowers:subagent-driven-development in the existing isolated worktree. The user has authorized implementation and merging the complete verified branch into main.

**Goal:** Add API-free source handoffs and contextual people-aware culling to the native Mac app, verify them, and merge the complete app into main.

**Architecture:** A pure staged importer and an AppKit promised-file receiver feed managed local albums. Extended per-face measurements and intent-aware scoring drive transparent recommendations. The existing native editor, session identity, and safe exporters remain shared across sources.

**Tech stack:** Swift, SwiftUI/AppKit, PhotosUI, Vision, ImageIO, Foundation, system zlib, XCTest; no external packages or service APIs.

## Task 1: Contextual face assessment (independent core owner)

Files: Models.swift, PhotoAnalyzer.swift, Scorer.swift; new PeopleAssessment.swift and PeopleAssessmentTests.swift; existing scoring tests as needed.

1. Add failing tests for backward decoding, separate eyes, pose/gaze uncertainty, occlusion/profile/small-face handling, intent-specific policy, and all significant group faces.
2. Run `swift test --filter PeopleAssessmentTests` in an isolated scratch path and record RED.
3. Extend FaceInfo with optional left/right openness, confidence/landmark support, pose and pupil-derived attention evidence. Preserve existing initializer compatibility; increment PhotoAnalysis.currentVersion.
4. Expose `ScoringOptions.shootingIntent` using a public Codable/CaseIterable `ShootingIntent` with title/help. Provide pure assessment helpers returning descriptive per-face observations/review reasons.
5. Integrate conservative issues/recommendations: clear closed eyes remain detectable; one-eye/pose/attention uncertainty stays for review; candid intent does not punish looking away, creative intent does not confidently reject softness. Keep existing default regressions passing.
6. Record GREEN and hand off interface details; no UI files or commits owned by the agent.

## Task 2: Managed local import and safe ZIP (independent core owner)

Files: new CullCore/PhotoImport.swift, SafeZIP.swift and PhotoImportTests.swift. Do not modify Models.swift or UI files.

Contract: public `ImportSourceKind` cases files, applePhotos, googlePhotos, browserDrop, takeout; a Codable `PhotoImportManifest`; and `PhotoImporter.importFiles(_:to:source:) throws -> PhotoImportResult` accepting local URLs, where destination is a new managed album. Result includes imported file count, manifest and warnings. Include optional progress callback and limits if needed; send exact signatures to root before integration.

1. Write RED tests for single/multiple files, recursive directories, pairing/collisions, companions, Takeout capture-date sidecars, source bytes unchanged, bad/remote files, and rollback/cancellation.
2. Add bounded ZIP tests for stored/deflate, CRC/truncation/encryption/ZIP64, path traversal/absolute paths/symlinks, duplicate paths and expanded-size limits.
3. Implement staging and atomic directory publication, no overwrite, no shell extraction. Use SDK zlib (available locally). Reject unsupported archives with actionable errors.
4. Preserve original relative names and per-item provenance; parse well-formed Takeout timestamp metadata without executing HTML/scripts or modifying photo originals. Provide a manifest reader for the UI's source summary.
5. Record focused GREEN and hand off contracts. No commits or unrelated source edits.

## Task 3: Native drop receiver (independent AppKit owner)

Files: new OpenCull/PhotoDropReceiver.swift and focused tests only.

Contract: `PhotoDropReceiver(isEnabled:onFiles:onFailure:)` SwiftUI NSViewRepresentable overlay. onFiles receives `[URL]` and the URLs remain readable until async import completes; communicate a cleanup handle if using a temporary promised-file directory. Prefer a public local drop payload type carrying cleanup ownership over prematurely deleting received files.

1. Reproduce classification/order bugs with pure tests: promises before URLs, multiple files, remote links rejected, unsupported payloads and cancellation cleanup.
2. Receive NSFilePromiseReceiver files on a background queue with bounded counts; deliver one batch on MainActor after callbacks finish. Never synchronously read sources in draggingEntered.
3. Accept Finder file URLs and promised image files from Photos/Safari; do not fetch HTTP/blob URLs or inspect browser credentials.
4. Add visible drag-target feedback without intercepting normal grid/editor clicks. Root wires lifecycle/import; no edits to ContentView or LibraryModel.

## Task 4: Native source/intent UI and import orchestration (root)

Files: LibraryModel.swift, ContentView.swift, SettingsView.swift, DetailView.swift, OpenCullApp.swift, new source/import views and UI-model tests.

1. Add RED integration tests for busy guards, cancellation/failure preserving the album, provenance restoration and safe managed import.
2. Add source actions for files/folders/ZIP, Apple Photos, Google Photos website/downloads/Takeout, and an explicit managed import inbox. Use async native panels and existing export/import guards.
3. Route individual drops and promised batches through PhotoImporter; maintain progress/errors/cancel and source provenance. Keep directory Open Folder behavior available without unnecessary copies.
4. Request current picker representations and retain available asset identifiers/type provenance; label representation uncertainty. No full-library permissions or cloud writeback.
5. Add intent picker and per-face evidence/reasons to review, including unknown states and explanation of background blur versus subject focus.
6. Test integration and source preservation; document no external API calls and Google handoff boundaries.

## Task 5: Review, verification, packaging and merge (root plus independent reviewers)

1. Review each task for approved scope, then code/data safety; fix concrete findings and re-review.
2. Run `swift test`, meaningful CLI A/B inputs, `scripts/build-app.sh` and `scripts/verify-release.sh`; inspect native import → review → edit → export with disposable inputs.
3. Update release version/docs and output app/source/verification/evidence with exact commit and checksums. No user photos in delivery evidence.
4. Push; wait for successful CI on exact head. Mark PR #1 ready and merge with expected_head_sha. Verify remote main contains the merge and archive matching source; report merged SHA and remaining validation limits. Do not stop for another merge permission request.
