import Foundation

enum TimecodeUtil {
    /// Group digits from the right while typing; pad to HH:MM:SS:FF on commit.
    static func formatInput(_ input: String) -> String {
        let digits = String(input.filter { $0.isASCII && $0.isNumber }.prefix(8))
        guard !digits.isEmpty else { return "" }
        var groups: [String] = []
        var remaining = digits
        while !remaining.isEmpty {
            groups.insert(String(remaining.suffix(2)), at: 0)
            remaining = String(remaining.dropLast(min(2, remaining.count)))
        }
        return groups.joined(separator: ":")
    }

    /// Format a frame count as timecode string "HH:MM:SS:FF"
    static func format(frames: Int, timebase: Int) -> String {
        let tc = Timecode.fromFrames(frames, timebase: timebase)
        return tc.description
    }

    /// Validate a timecode string format
    static func isValid(_ string: String, timebase: Int) -> Bool {
        Timecode.parse(string, timebase: timebase) != nil
    }

    /// Convert timeline frame position to absolute timecode
    static func timelineFrameToAbsoluteTC(frame: Int, startTC: Timecode) -> Timecode {
        startTC.adding(frames: frame)
    }

    /// Convert absolute timecode to timeline frame position
    static func absoluteTCToTimelineFrame(absoluteTC: Timecode, startTC: Timecode) -> Int {
        absoluteTC.framesDifference(from: startTC)
    }
}
