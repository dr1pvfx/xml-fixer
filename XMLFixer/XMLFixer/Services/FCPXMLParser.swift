import Foundation

struct FCPXMLParser {

    // MARK: - FPS Computation Helper

    /// Compute the effective frames-per-second from a timebase and NTSC flag.
    /// For NTSC (drop-frame), applies the 1000/1001 factor (e.g. timebase 24 → 23.976).
    static func computeFPS(timebase: Int, ntsc: Bool) -> Double {
        if ntsc {
            return Double(timebase) * 1000.0 / 1001.0
        }
        return Double(timebase)
    }

    /// Parse a file URL into an FCPXMLDocument with all metadata extracted.
    static func parse(url: URL) throws -> FCPXMLDocument {
        let data = try Data(contentsOf: url)
        let xmlDoc = try XMLDocument(data: data, options: [.nodePreserveAll])

        let docID = UUID()
        let sequenceElements = try extractSequenceElements(from: xmlDoc)

        let sequences = sequenceElements.map { seq -> SequenceInfo in
            let videoTrackCount = (try? seq.nodes(forXPath: "media/video/track"))?.count ?? 0
            let audioTrackCount = (try? seq.nodes(forXPath: "media/audio/track"))?.count ?? 0

            // Compute FPS from sequence rate
            let seqTimebase = seq.singleIntValue(forXPath: "rate/timebase")
            let seqNtsc = seq.singleStringValue(forXPath: "rate/ntsc")?.uppercased() == "TRUE"
            let fps: Double? = seqTimebase.map { computeFPS(timebase: $0, ntsc: seqNtsc) }

            // Determine audio channel info from track premiereTrackType attributes
            let audioChannelInfo: String? = {
                guard let audioTracks = try? seq.nodes(forXPath: "media/audio/track") else { return nil }
                var trackTypes: Set<String> = []
                for trackNode in audioTracks {
                    guard let trackElem = trackNode as? XMLElement else { continue }
                    if let premiereType = trackElem.attributeValue(forName: "premiereTrackType") {
                        trackTypes.insert(premiereType.lowercased())
                    }
                }
                if trackTypes.isEmpty { return nil }
                if trackTypes.count == 1 {
                    let single = trackTypes.first!
                    if single == "mono" { return "Mono" }
                    if single == "stereo" { return "Stereo" }
                    return single.capitalized
                }
                return "Mixed"
            }()

            // Check for nested sequences
            let nestedSeqNodes = (try? seq.nodes(forXPath: "media/video/track/clipitem/sequence")) ?? []
            let hasNestedSequences = !nestedSeqNodes.isEmpty
            let nestedSequenceCount = nestedSeqNodes.count

            // Parse sequence-level timecode
            let startTCString = seq.singleStringValue(forXPath: "timecode/string")
            let startTCDisplayFormat = seq.singleStringValue(forXPath: "timecode/displayformat")
            let startTCFrame = seq.singleIntValue(forXPath: "timecode/frame")
                ?? startTCString.flatMap { Timecode.parse($0, timebase: seqTimebase ?? 25,
                    dropFrame: startTCDisplayFormat == "DF")?.totalFrames }

            return SequenceInfo(
                sequenceElementID: seq.attributeValue(forName: "id"),
                name: seq.singleStringValue(forXPath: "name") ?? "Untitled",
                duration: seq.singleIntValue(forXPath: "duration"),
                timebase: seqTimebase,
                videoTrackCount: videoTrackCount,
                audioTrackCount: audioTrackCount,
                parentDocumentID: docID,
                fps: fps,
                audioChannelInfo: audioChannelInfo,
                hasNestedSequences: hasNestedSequences,
                nestedSequenceCount: nestedSequenceCount,
                startTimecodeString: startTCString,
                startTimecodeFrame: startTCFrame,
                startTimecodeDisplayFormat: startTCDisplayFormat,
                ntsc: seqNtsc
            )
        }

        return FCPXMLDocument(
            id: docID,
            sourceURL: url,
            displayName: url.deletingPathExtension().lastPathComponent,
            xmlDocument: xmlDoc,
            sequences: sequences
        )
    }

    // MARK: - File metadata pre-scan helper

    /// Container for metadata extracted from a `<file>` element, including timecode and media properties.
    private struct FileMetadata {
        var reelName: String?
        var timecodeString: String?
        var timecodeFrame: Int?
        var displayFormat: String?
        var fps: Double?
        var resolution: String?
        var codec: String?
        var audioChannels: Int?
        var sourceDurationFrames: Int?
    }

    /// Build a lookup table of file metadata keyed by file element `id`.
    /// Scans ALL `<file>` elements in the document (including root-level definitions)
    /// so that inline stub references like `<file id="file3"/>` can still resolve metadata.
    private static func buildFileMetadataMap(from xmlDoc: XMLDocument) -> [String: FileMetadata] {
        guard let root = xmlDoc.rootElement() else { return [:] }
        guard let fileNodes = try? root.nodes(forXPath: "//file[@id]") else { return [:] }

        var map: [String: FileMetadata] = [:]
        for node in fileNodes {
            guard let elem = node as? XMLElement,
                  let fileID = elem.attributeValue(forName: "id")
            else { continue }

            // Timecode metadata
            let reelName = elem.singleStringValue(forXPath: "timecode/reel/name")
            let timecodeString = elem.singleStringValue(forXPath: "timecode/string")
            let timecodeFrame = elem.singleIntValue(forXPath: "timecode/frame")
            let displayFormat = elem.singleStringValue(forXPath: "timecode/displayformat")

            // FPS from file rate
            let fileTimebase = elem.singleIntValue(forXPath: "rate/timebase")
            let fileNtsc = elem.singleStringValue(forXPath: "rate/ntsc")?.uppercased() == "TRUE"
            let fps: Double? = fileTimebase.map { computeFPS(timebase: $0, ntsc: fileNtsc) }

            // Resolution from media/video/samplecharacteristics
            let width = elem.singleIntValue(forXPath: "media/video/samplecharacteristics/width")
            let height = elem.singleIntValue(forXPath: "media/video/samplecharacteristics/height")
            let resolution: String? = {
                if let w = width, let h = height {
                    return "\(w)x\(h)"
                }
                return nil
            }()

            // Codec name
            let codec = elem.singleStringValue(forXPath: "media/video/samplecharacteristics/codec/name")

            // Audio channel count
            let audioChannels = elem.singleIntValue(forXPath: "media/audio/channelcount")

            // Source duration in frames
            let sourceDurationFrames = elem.singleIntValue(forXPath: "duration")

            let info = FileMetadata(
                reelName: reelName,
                timecodeString: timecodeString,
                timecodeFrame: timecodeFrame,
                displayFormat: displayFormat,
                fps: fps,
                resolution: resolution,
                codec: codec,
                audioChannels: audioChannels,
                sourceDurationFrames: sourceDurationFrames
            )

            // If we already have an entry with richer data, merge rather than overwrite.
            if let existing = map[fileID] {
                map[fileID] = FileMetadata(
                    reelName: existing.reelName ?? info.reelName,
                    timecodeString: existing.timecodeString ?? info.timecodeString,
                    timecodeFrame: existing.timecodeFrame ?? info.timecodeFrame,
                    displayFormat: existing.displayFormat ?? info.displayFormat,
                    fps: existing.fps ?? info.fps,
                    resolution: existing.resolution ?? info.resolution,
                    codec: existing.codec ?? info.codec,
                    audioChannels: existing.audioChannels ?? info.audioChannels,
                    sourceDurationFrames: existing.sourceDurationFrames ?? info.sourceDurationFrames
                )
            } else {
                map[fileID] = info
            }
        }
        return map
    }

    /// Walk up the DOM from a clipitem to find the enclosing `<sequence>` element's name.
    /// Expected hierarchy: clipitem -> track -> video/audio -> media -> sequence
    private static func enclosingSequenceName(for clipElement: XMLElement) -> String? {
        var current: XMLNode? = clipElement
        for _ in 0..<4 {
            current = current?.parent
        }
        guard let seqElement = current as? XMLElement,
              seqElement.name == "sequence"
        else { return nil }
        return seqElement.singleStringValue(forXPath: "name")
    }

    /// Build unified media reference list across multiple documents.
    /// Groups by filename — so if 2000 XMLs reference "logo.png", you get ONE MediaReference.
    static func extractMediaReferences(from documents: [FCPXMLDocument]) -> [MediaReference] {
        var mediaByFilename: [String: MediaReference] = [:]

        for doc in documents {
            guard let root = doc.xmlDocument.rootElement() else { continue }

            // Pre-scan: build file metadata lookup for this document
            let fileMetadataMap = buildFileMetadataMap(from: doc.xmlDocument)

            // Build file_map for this document: file@id -> filename
            let localFileMap = FCPXMLMutator.buildFileMap(from: doc.xmlDocument)

            // Scan ALL clipitems (video + audio) to find media references
            let xpaths = [
                "//sequence/media/video/track/clipitem",
                "//sequence/media/audio/track/clipitem"
            ]

            for xpath in xpaths {
                guard let clipNodes = try? root.nodes(forXPath: xpath) else { continue }

                for clipNode in clipNodes {
                    guard let clipElem = clipNode as? XMLElement,
                          let fileElem = (try? clipElem.nodes(forXPath: "file"))?.first as? XMLElement
                    else { continue }

                    let fileID = fileElem.attributeValue(forName: "id")

                    // Resolve filename: try direct <name> child first, then file_map lookup
                    let filename: String? = {
                        if let directName = fileElem.singleStringValue(forXPath: "name"),
                           !directName.isEmpty {
                            return directName
                        }
                        if let fid = fileID {
                            return localFileMap[fid]
                        }
                        return nil
                    }()

                    guard let resolvedName = filename else { continue }

                    let pathURL = fileElem.singleStringValue(forXPath: "pathurl")

                    // Resolve metadata: prefer inline element, fall back to pre-scanned map
                    let preScan = fileID.flatMap { fileMetadataMap[$0] }

                    // Timecode fields
                    let inlineReelName = fileElem.singleStringValue(forXPath: "timecode/reel/name")
                    let inlineTimecodeString = fileElem.singleStringValue(forXPath: "timecode/string")
                    let inlineTimecodeFrame = fileElem.singleIntValue(forXPath: "timecode/frame")
                    let inlineDisplayFormat = fileElem.singleStringValue(forXPath: "timecode/displayformat")

                    let reelName = inlineReelName ?? preScan?.reelName
                    let timecodeString = inlineTimecodeString ?? preScan?.timecodeString
                    let timecodeFrame = inlineTimecodeFrame ?? preScan?.timecodeFrame
                    let displayFormat = inlineDisplayFormat ?? preScan?.displayFormat

                    // Extended metadata fields — prefer inline, fall back to pre-scanned map
                    let inlineFPS: Double? = {
                        if let tb = fileElem.singleIntValue(forXPath: "rate/timebase") {
                            let ntsc = fileElem.singleStringValue(forXPath: "rate/ntsc")?.uppercased() == "TRUE"
                            return computeFPS(timebase: tb, ntsc: ntsc)
                        }
                        return nil
                    }()
                    let fps = inlineFPS ?? preScan?.fps

                    let inlineResolution: String? = {
                        if let w = fileElem.singleIntValue(forXPath: "media/video/samplecharacteristics/width"),
                           let h = fileElem.singleIntValue(forXPath: "media/video/samplecharacteristics/height") {
                            return "\(w)x\(h)"
                        }
                        return nil
                    }()
                    let resolution = inlineResolution ?? preScan?.resolution

                    let inlineCodec = fileElem.singleStringValue(forXPath: "media/video/samplecharacteristics/codec/name")
                    let codec = inlineCodec ?? preScan?.codec

                    let inlineAudioChannels = fileElem.singleIntValue(forXPath: "media/audio/channelcount")
                    let audioChannels = inlineAudioChannels ?? preScan?.audioChannels

                    let inlineSourceDuration = fileElem.singleIntValue(forXPath: "duration")
                    let sourceDurationFrames = inlineSourceDuration ?? preScan?.sourceDurationFrames

                    // Check if this clipitem has a speed/variablespeed effect (timewarp)
                    let isTimewarped: Bool = {
                        guard let filterNodes = try? clipElem.nodes(forXPath: "filter/effect/name") else { return false }
                        for filterNode in filterNodes {
                            if let value = filterNode.stringValue?.lowercased(),
                               (value.contains("speed") || value.contains("timewarp")) {
                                return true
                            }
                        }
                        // Also check parameterid for variablespeed
                        guard let paramNodes = try? clipElem.nodes(forXPath: "filter/effect/parameter/parameterid") else { return false }
                        for paramNode in paramNodes {
                            if let value = paramNode.stringValue?.lowercased(),
                               (value.contains("speed") || value.contains("variablespeed")) {
                                return true
                            }
                        }
                        return false
                    }()

                    // Extract the parent sequence name for this clipitem
                    let seqName = enclosingSequenceName(for: clipElem)
                    let seqRef: MediaReference.SequenceRef? = seqName.map {
                        MediaReference.SequenceRef(documentID: doc.id, sequenceName: $0)
                    }

                    if var existing = mediaByFilename[resolvedName] {
                        existing.referencingDocuments.insert(doc.id)
                        existing.clipCount += 1
                        if let fid = fileID { existing.fileElementIDs.insert(fid) }

                        // Backfill timecode fields if the existing entry had nils
                        if existing.reelName == nil { existing.reelName = reelName }
                        if existing.timecodeString == nil { existing.timecodeString = timecodeString }
                        if existing.timecodeFrame == nil { existing.timecodeFrame = timecodeFrame }
                        if existing.displayFormat == nil { existing.displayFormat = displayFormat }

                        // Backfill extended metadata fields
                        if existing.fps == nil { existing.fps = fps }
                        if existing.resolution == nil { existing.resolution = resolution }
                        if existing.codec == nil { existing.codec = codec }
                        if existing.audioChannels == nil { existing.audioChannels = audioChannels }
                        if existing.sourceDurationFrames == nil { existing.sourceDurationFrames = sourceDurationFrames }

                        // Timewarp uses OR logic — true if any clipitem referencing this file is timewarped
                        existing.isTimewarped = existing.isTimewarped || isTimewarped

                        // Add sequence back-reference
                        if let ref = seqRef { existing.referencingSequences.insert(ref) }

                        mediaByFilename[resolvedName] = existing
                    } else {
                        var initialSequences: Set<MediaReference.SequenceRef> = []
                        if let ref = seqRef { initialSequences.insert(ref) }

                        mediaByFilename[resolvedName] = MediaReference(
                            filename: resolvedName,
                            pathURL: pathURL,
                            fileElementIDs: fileID.map { Set([$0]) } ?? [],
                            referencingDocuments: [doc.id],
                            clipCount: 1,
                            reelName: reelName,
                            timecodeString: timecodeString,
                            timecodeFrame: timecodeFrame,
                            displayFormat: displayFormat,
                            referencingSequences: initialSequences,
                            fps: fps,
                            resolution: resolution,
                            codec: codec,
                            audioChannels: audioChannels,
                            sourceDurationFrames: sourceDurationFrames,
                            isTimewarped: isTimewarped
                        )
                    }
                }
            }
        }

        return Array(mediaByFilename.values).sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    // MARK: - Private

    private static func extractSequenceElements(from doc: XMLDocument) throws -> [XMLElement] {
        guard let root = doc.rootElement() else { return [] }
        let nodes = try root.nodes(forXPath: "//sequence")
        return nodes.compactMap { $0 as? XMLElement }
    }
}
