# OpenCull Native Workflow Implementation Plan

**Goal:** Repair the audited failures and deliver a complete local native photography culling-to-editing-to-export workflow.

**Architecture:** CullCore owns metadata, scanning, analysis, preferences and Core Image rendering. LibraryModel coordinates versioned sessions, bounded analysis, review, editing, history and export. SwiftUI presents Cull, Compare and Edit modes.

**Tech Stack:** Swift 5.10+, modern macOS SDK, SwiftUI/AppKit, Core Image, ImageIO, Vision, PhotosUI, XCTest.

## 1. Metadata and durable identity
- Files: CullCore/XMPSidecar.swift, Persistence.swift; new MetadataSafetyTests.swift.
- First add failing tests for external metadata preservation, comment/namespace/typed-element RDF, mixed bundle collisions and stale choice export.
- Implement namespace-aware updates, source-preserving backups and atomic bundle copying with destination metadata generated from current choices.
- Add versioned entries and throwing load APIs, dependency-aware keys, explicit clear operation. Verify old tests and regressions.

## 2. Culling and scanner correctness
- Files: Models.swift, GrayImage.swift, PhotoAnalyzer.swift, ImageLoader.swift, Grouper.swift, Scorer.swift, PhotoScanner.swift, CLI/main.swift; new CullingRegressionTests.swift and PreferenceTests.swift.
- Capture failing tests for same-stem overpairing, group chains, noise/patch attacks and recursive invalid input.
- Add conservative grouping and focus safeguards, diagnostic status/classification labels, independent duplicate discovery, local preference model and target selection.
- Keep new analysis fields backwards decodable or bump cache version. Prove the CLI race removed with Thread Sanitizer.

## 3. Nondestructive editing engine
- New CullCore/Editing.swift and EditingTests.swift.
- Tests first for neutral identity, exposure/color changes, orientation, crop/rotation dimensions, input preservation, file collisions and encoded export formats.
- Implement Codable/EditRecipe, presets/styles and shared preview/full-resolution render pipeline with sRGB output. Bound controls and reject invalid recipes.

## 4. Workspace persistence and actions
- Files: OpenCull/LibraryModel.swift, new WorkspaceState.swift; new Tests/OpenCullTests.
- Tests first for selection/filter, navigation, accept/open busy guards, save failures, shutdown flush, version checks, recipe restore and undo/redo including bulk edits.
- Add recent albums, recursive option, selection sets, compare state, group overrides, search, target cull, preference recording, edit sessions and rendered export coordination.

## 5. Native review/editor UI
- Files: ContentView.swift, DetailView.swift, GridView.swift, PreviewCache.swift, SettingsView.swift, OpenCullApp.swift; new editor/compare/zoom/import views.
- Wire edit recipes, before/after, histogram, preset/style management, crop/straighten controls and batch application. Show versioned preview loading/error states and meaningful progress.
- Add fit/100%/face zoom, synchronized comparison, local semantic search, Photos picker, recent sessions and keyboard/menu parity. Add save status and proper termination flush.

## 6. Review, delivery and acceptance
- Update README, build script, version and CI with the actual feature set and requirements.
- Independently review requirements, then code quality, repairing findings before final validation.
- Execute all tests; run image A/B suite and TSan; build universal release; verify archive/signature; inspect native review/edit/export flows.
- Deliver source and app ZIP, regression evidence and a requirements/fix ledger. Keep branch reviewable; do not overwrite a user's installed app or publish a release implicitly.
