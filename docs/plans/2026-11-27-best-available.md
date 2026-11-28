# Best available group portrait implementation plan

A photographer reviewing a posed burst should be able to open the strongest available original and its runner-up, read what distinguishes them, and inspect the relevant faces before making a choice. All analysis and image display run on the Mac.

1. Add a pure CullCore burst recommender. Use existing measurements, compare group coverage as well as supported eye and attention evidence, and use focus to distinguish comparable expressions. Return a stable top two, the decisive difference, honest close calls, and indices into each original frame. Test imperfect bursts, missing and ambiguous faces, focus, technical failures, ties and reordered inputs.
2. Integrate the recommendation in LibraryModel after grouping. Compute once per group, independent of filters. Test that recommendations follow intent, regrouping and album changes, that an explicit pick applies to the shown photograph, and that bulk actions preserve close calls for review.
3. Add the native comparison sheet to grid and detail. Display original oriented image pixels, handle missing matches explicitly, and let the photographer pick either frame. Exercise the feature in a disposable album, including opening the comparison and making a choice.
4. Update documentation, installer version and release notes for 0.4.0. Run the full Swift suite and verify the universal DMG. Review, merge, publish a new GitHub release, and check the public installer against the published checksum.
