# RPB XML Toolkit

**A fast, native macOS workspace for repairing and preparing Final Cut Pro XML.**

RPB XML Toolkit helps post-production teams inspect, clean up, relink, and export
large batches of Final Cut Pro `xmeml` v4/v5 XML files. It keeps the original XML
structure in memory while giving you a practical visual workspace for media,
timelines, source timecode, and reference video.

> **Alpha software:** The current public build is intended for evaluation on
> copies of your project XML. Keep backups of original media and timelines.

## Download

Get the latest **Developer ID–signed and Apple-notarized** alpha build from the
[v1.0.0 Alpha 2 release](https://github.com/dr1pvfx/xml-fixer/releases/tag/v1.0.0-alpha.2).

**Requirements:** macOS 14 Sonoma or later.

## What it does

- Import individual XML files, folders, or drop files directly onto the app.
- Inspect media across all loaded XMLs in one deduplicated list.
- Browse timelines visually, scrub a frame-accurate playhead, and inspect clips
  and effects.
- Link reference videos and synchronize them with the active timeline using
  source timecode.
- Relink media paths to a new conform location and copy linked media into a
  collected delivery folder.
- Match reference videos to timelines, including review and manual overrides
  before applying matches.
- Edit filenames, paths, reel metadata, and timeline start timecode.
- Remove selected media, strip audio tracks, flatten nested sequences, and
  batch-rename timelines.
- Export updated XMLs, a concise media CSV, or a Sources Sequence XML containing
  the best-length source ranges for a conform workflow.
- Calculate common scale and resize values without leaving the app.

## Typical workflow

1. **Import** the XML files or the containing folder.
2. **Review** the consolidated media list and timeline view.
3. **Repair** paths, names, timecode, reel metadata, or sequence structure.
4. **Relink or collect** media when preparing a handoff.
5. **Export** revised XMLs, a Sources Sequence XML, and/or a CSV report.

All XML mutations are applied to an in-memory document and can be undone during
the session. The original files are not overwritten unless you explicitly choose
their location as the export destination.

### Reference timecode

References match their embedded timecode by default. For example, a sequence
starting at `00:59:59:00` with a 25fps reference starting at `01:00:00:00` shows
one second of **Out of reference range** before the first reference image.
Changing the sequence start timecode immediately updates the reference alignment.

Select **Ignore reference timecode** in Match Reference Files or the player to
place reference frame zero at sequence frame zero. Use this for references with
missing or intentionally unrelated timecode. Areas before or after the reference
remain blank while the sequence playhead continues normally.

Timecode fields accept compact digits such as `01000000`, insert separators,
and validate frame numbers against each sequence's frame rate.

## Built for post workflows

| Area | Capabilities |
| --- | --- |
| Media management | Consolidated media inspection, bulk edits, filename changes, relinking, and collection |
| Timeline cleanup | Batch timeline renaming, nested-sequence flattening, audio stripping, and clip removal |
| Timecode & review | Source-timecode display, timeline start-timecode editing, and synchronized reference playback |
| Delivery | Updated XML batch export, CSV media report, and Sources Sequence XML export |

## Build from source

The app has no external runtime dependencies. Open
`XMLFixer/XMLFixer.xcodeproj` in Xcode, select the `XMLFixer` scheme, and run it.

Or build and test from Terminal:

```bash
# Clone the project
git clone https://github.com/dr1pvfx/xml-fixer.git
cd xml-fixer

# Run the test suite without requiring local signing credentials
xcodebuild -project XMLFixer/XMLFixer.xcodeproj -scheme XMLFixer \
  -configuration Debug -derivedDataPath /tmp/xml-fixer-derived test \
  CODE_SIGNING_ALLOWED=NO

# Create a local release build
xcodebuild -project XMLFixer/XMLFixer.xcodeproj -scheme XMLFixer \
  -configuration Release -derivedDataPath /tmp/xml-fixer-derived build \
  CODE_SIGNING_ALLOWED=NO
```

The local release app is written to:

```text
/tmp/xml-fixer-derived/Build/Products/Release/RPB XML Toolkit.app
```

## Project structure

```text
XMLFixer/
├── XMLFixer/          # SwiftUI app source
│   ├── Models/         # XML, timeline, media, and export types
│   ├── Services/       # Parsing, mutation, matching, relinking, and export
│   ├── ViewModels/     # Central AppState and application workflows
│   └── Views/          # Sidebar, media, timeline, player, and action sheets
├── XMLFixerTests/      # XCTest coverage and XML fixtures
└── project.yml         # XcodeGen project definition
```

## Development notes

`FCPXMLDocument.xmlDocument` is the source of truth for an imported document.
Changes operate directly on that XML document and are serialized only at export.
The detailed architecture and project conventions live in
[CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).

## Feedback

This is an alpha release. If you encounter an XML structure, media format, or
workflow that needs better support, please [open an issue](https://github.com/dr1pvfx/xml-fixer/issues) with a reproducible description. Do not attach sensitive production media or client XML unless you are authorized to share it.
