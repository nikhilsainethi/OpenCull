# Native culling and editing design

Approved direction: the user requested all audit fixes and the missing native culling/editing workflow, with general-photography defaults. Keep the application local and preserve originals.

## Architecture

Retain SwiftUI/AppKit and the testable CullCore module. Use ImageIO/Core Image for color-managed, nondestructive edits. Store a versioned edit recipe separately from original image data; render preview and export through the same pipeline. User choices, edits, group overrides and preferences persist with file identity checks and visible save errors. Native undo/redo covers individual and bulk operations.

The review workspace offers Cull, Compare and Edit modes, a searchable filmstrip/grid, real fit/100%/face zoom and 2-4 image comparison. Batch selection supports decisions, ratings and edit propagation. Recursive folder import, recent albums and a Photos picker import copies into a local managed album. Originals are never rewritten.

Culling becomes conservative: robust multiscale focus metrics, representative-bounded similarity groups, an optional full-library exact-duplicate pass, explicit incomplete-analysis/review status, adjustable layout and exposure thresholds, manual split/merge, subject-face review, target-count selection and local preference adaptation from explicit decisions. Search uses filenames and local Vision classifications; it does not claim a downloaded CLIP model.

Editing includes exposure, white balance/tint, contrast, highlights/shadows, saturation/vibrance, sharpness/noise reduction, rotation/straightening and normalized crop; reset, before/after, local presets, saved styles, auto-adjust and batch application. Export rendered JPEG/PNG/TIFF at full resolution or a selected long edge, with metadata policy and collision-safe filenames.

## Audit acceptance

F01-F04: namespace-aware XMP editing with backups, valid XML/RDF, transactional photo-bundle export, current metadata and explicit clearing. F05-F07: dependency-aware identity and narrowly defined pairing. F08-F11/F14-F15: visible-selection invariants, logical group navigation, guarded actions, atomic open, tunable thresholds and terminal preview failures. F12-F13: immutable CLI jobs, synchronized result collection and proper recursive errors. R01-R07: save/corruption status, versioned decisions, export serialization, Vision diagnostics, clear synchronization, correct SDK requirement and release verification.

## Verification

Turn every reproducible audit issue into a failing regression before changing that behavior. Test real pixel rendering, source preservation, recipes, export identity and persistence, UI model operations, batching and history. Run the full test suite, build universal artifacts, verify signatures/ZIP extraction, rerun adversarial A/B inputs and Thread Sanitizer, and exercise native UI on disposable photos. Report external-editor, unsupported-camera and human-preference validation honestly.
