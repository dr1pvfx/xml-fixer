import Foundation

struct TimelineExtractor {

    static func extractTimeline(for sequenceInfo: SequenceInfo, from document: FCPXMLDocument) -> TimelineData? {
        guard let root = document.xmlDocument.rootElement() else { return nil }

        let sequenceElement: XMLElement? = {
            if let seqID = sequenceInfo.sequenceElementID {
                return (try? root.nodes(forXPath: "//sequence[@id='\(seqID)']"))?.first as? XMLElement
            }
            return (try? root.nodes(forXPath: "//sequence"))?.compactMap({ $0 as? XMLElement })
                .first { $0.singleStringValue(forXPath: "name") == sequenceInfo.name }
        }()

        guard let seqElem = sequenceElement else { return nil }

        let fileMap = FCPXMLMutator.buildFileMap(from: document.xmlDocument)
        let fileTimecodeMap = buildFileTimecodeMap(from: document.xmlDocument)
        let totalDuration = seqElem.singleIntValue(forXPath: "duration") ?? 0
        let timebase = seqElem.singleIntValue(forXPath: "rate/timebase") ?? 25

        let videoTrackNodes = (try? seqElem.nodes(forXPath: "media/video/track")) ?? []
        let videoTracks = videoTrackNodes.enumerated().compactMap { index, node -> TimelineTrack? in
            guard let trackElem = node as? XMLElement else { return nil }
            let clips = extractClips(from: trackElem, trackIndex: index, trackType: .video, fileMap: fileMap, fileTimecodeMap: fileTimecodeMap, timebase: timebase)
            guard !clips.isEmpty else { return nil }
            return TimelineTrack(index: index, trackType: .video, clips: clips.sorted { $0.startFrame < $1.startFrame })
        }

        let audioTrackNodes = (try? seqElem.nodes(forXPath: "media/audio/track")) ?? []
        let audioTracks = audioTrackNodes.enumerated().compactMap { index, node -> TimelineTrack? in
            guard let trackElem = node as? XMLElement else { return nil }
            let clips = extractClips(from: trackElem, trackIndex: index, trackType: .audio, fileMap: fileMap, fileTimecodeMap: fileTimecodeMap, timebase: timebase)
            guard !clips.isEmpty else { return nil }
            return TimelineTrack(index: index, trackType: .audio, clips: clips.sorted { $0.startFrame < $1.startFrame })
        }

        let allClips = videoTracks.flatMap(\.clips) + audioTracks.flatMap(\.clips)
        let uniqueFilenames = Set(allClips.map(\.filename))

        // Parse start timecode from the sequence element
        let startTCString = seqElem.singleStringValue(forXPath: "timecode/string")
        var startTCFrame = seqElem.singleIntValue(forXPath: "timecode/frame") ?? 0
        let ntsc = seqElem.singleStringValue(forXPath: "rate/ntsc")?.uppercased() == "TRUE"

        // If <frame> element is missing but <string> is present, parse the TC string
        if startTCFrame == 0, let tcString = startTCString,
           let parsed = Timecode.parse(tcString, timebase: timebase, dropFrame: seqElem.singleStringValue(forXPath: "timecode/displayformat") == "DF") {
            startTCFrame = parsed.totalFrames
        }

        return TimelineData(
            sequenceName: sequenceInfo.name,
            documentID: document.id,
            sequenceID: sequenceInfo.id,
            totalDurationFrames: totalDuration,
            timebase: timebase,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            uniqueFilenames: uniqueFilenames,
            startTimecodeFrame: startTCFrame,
            startTimecodeString: startTCString,
            ntsc: ntsc
        )
    }

    private static func extractClips(from trackElement: XMLElement, trackIndex: Int, trackType: TimelineClip.TrackType, fileMap: [String: String], fileTimecodeMap: [String: Int], timebase: Int) -> [TimelineClip] {
        guard let clipNodes = try? trackElement.nodes(forXPath: "clipitem") else { return [] }

        return clipNodes.compactMap { node -> TimelineClip? in
            guard let clipElem = node as? XMLElement else { return nil }
            guard let startFrame = clipElem.singleIntValue(forXPath: "start"),
                  let endFrame = clipElem.singleIntValue(forXPath: "end"),
                  startFrame >= 0, endFrame > startFrame
            else { return nil }

            let clipName = clipElem.singleStringValue(forXPath: "name") ?? "Untitled"
            let clipElementID = clipElem.attributeValue(forName: "id")
            let fileElem = (try? clipElem.nodes(forXPath: "file"))?.first as? XMLElement
            let fileElementID = fileElem?.attributeValue(forName: "id")

            let filename: String = {
                if let directName = fileElem?.singleStringValue(forXPath: "name"), !directName.isEmpty { return directName }
                if let fid = fileElementID { return fileMap[fid] ?? clipName }
                return clipName
            }()

            // Resolve file's starting timecode frame (inline first, then pre-scanned map)
            let fileStartTCFrame: Int = {
                if let inlineFrame = fileElem?.singleIntValue(forXPath: "timecode/frame") {
                    return inlineFrame
                }
                if let inlineTCString = fileElem?.singleStringValue(forXPath: "timecode/string"),
                   let parsed = Timecode.parse(inlineTCString, timebase: timebase) {
                    return parsed.totalFrames
                }
                if let fid = fileElementID { return fileTimecodeMap[fid] ?? 0 }
                return 0
            }()

            // Extract effects (filters and motion)
            let effects = extractEffects(from: clipElem)

            return TimelineClip(
                startFrame: startFrame,
                endFrame: endFrame,
                sourceInFrame: clipElem.singleIntValue(forXPath: "in") ?? 0,
                sourceOutFrame: clipElem.singleIntValue(forXPath: "out") ?? 0,
                sourceDuration: clipElem.singleIntValue(forXPath: "duration") ?? 0,
                fileStartTimecodeFrame: fileStartTCFrame,
                clipName: clipName,
                filename: filename,
                fileElementID: fileElementID,
                clipElementID: clipElementID,
                trackIndex: trackIndex,
                trackType: trackType,
                effects: effects
            )
        }
    }

    /// Build lookup of file element ID → starting timecode frame from all `<file>` elements.
    private static func buildFileTimecodeMap(from xmlDoc: XMLDocument) -> [String: Int] {
        guard let root = xmlDoc.rootElement(),
              let fileNodes = try? root.nodes(forXPath: "//file[@id]")
        else { return [:] }

        var map: [String: Int] = [:]
        for node in fileNodes {
            guard let elem = node as? XMLElement,
                  let fileID = elem.attributeValue(forName: "id")
            else { continue }

            if let frame = elem.singleIntValue(forXPath: "timecode/frame") {
                map[fileID] = frame
            } else if let tcString = elem.singleStringValue(forXPath: "timecode/string") {
                let tb = elem.singleIntValue(forXPath: "rate/timebase") ?? 25
                if let parsed = Timecode.parse(tcString, timebase: tb) {
                    map[fileID] = parsed.totalFrames
                }
            }
        }
        return map
    }

    private static func extractEffects(from clipElement: XMLElement) -> [ClipEffect] {
        var effects: [ClipEffect] = []

        // Parse <filter> elements (applied effects)
        if let filterNodes = try? clipElement.nodes(forXPath: "filter") {
            for (filterIndex, filterNode) in filterNodes.enumerated() {
                guard let filterElem = filterNode as? XMLElement,
                      let effectElem = (try? filterElem.nodes(forXPath: "effect"))?.first as? XMLElement
                else { continue }

                let effectName = effectElem.singleStringValue(forXPath: "name") ?? "Unknown"
                let effectID = effectElem.singleStringValue(forXPath: "effectid")
                let effectCategory = effectElem.singleStringValue(forXPath: "effectcategory")
                let effectType = effectElem.singleStringValue(forXPath: "effecttype")

                let parameters = extractParameters(from: effectElem)

                effects.append(ClipEffect(
                    name: effectName,
                    effectID: effectID,
                    effectCategory: effectCategory,
                    effectType: effectType,
                    filterIndex: filterIndex,
                    parameters: parameters
                ))
            }
        }

        return effects
    }

    private static func extractParameters(from effectElement: XMLElement) -> [ClipParameter] {
        guard let paramNodes = try? effectElement.nodes(forXPath: "parameter") else { return [] }

        return paramNodes.compactMap { node -> ClipParameter? in
            guard let paramElem = node as? XMLElement else { return nil }
            let parameterID = paramElem.singleStringValue(forXPath: "parameterid") ?? ""
            let name = paramElem.singleStringValue(forXPath: "name") ?? parameterID
            let value = paramElem.singleStringValue(forXPath: "value")
            let valueMin = paramElem.singleStringValue(forXPath: "valuemin")
            let valueMax = paramElem.singleStringValue(forXPath: "valuemax")

            // Parse keyframes
            var keyframes: [ClipKeyframe] = []
            if let keyframeNodes = try? paramElem.nodes(forXPath: "keyframe") {
                for kfNode in keyframeNodes {
                    guard let kfElem = kfNode as? XMLElement else { continue }
                    let when = kfElem.singleStringValue(forXPath: "when") ?? ""
                    let kfValue = kfElem.singleStringValue(forXPath: "value") ?? ""
                    keyframes.append(ClipKeyframe(when: when, value: kfValue))
                }
            }

            return ClipParameter(
                parameterID: parameterID,
                name: name,
                value: value,
                valueMin: valueMin,
                valueMax: valueMax,
                keyframes: keyframes
            )
        }
    }
}
