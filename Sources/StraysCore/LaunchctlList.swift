import Foundation

/// Parses `launchctl list` output: "PID\tStatus\tLabel", "-" for jobs that aren't running.
public enum LaunchctlList {
    public static func parse(_ text: String) -> [Int32: String] {
        var out: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let pid = Int32(fields[0]), pid > 1 else { continue }
            out[pid] = String(fields[2])
        }
        return out
    }
}
