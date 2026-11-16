import Foundation

/// Global shortcut that opens the panel.
public enum HotKeyChoice: String, Codable, Sendable, CaseIterable {
    case off
    case controlOptionP
    case controlOptionS
    case commandShiftOptionP

    public var label: String {
        switch self {
        case .off: "Off"
        case .controlOptionP: "⌃⌥P"
        case .controlOptionS: "⌃⌥S"
        case .commandShiftOptionP: "⌥⇧⌘P"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    /// No meaningful CPU (or an idle AI session) for this long counts as idle.
    public var idleHours: Double = 3
    /// Running longer than this counts as old.
    public var oldHours: Double = 24
    /// Below this share of one CPU core, a process counts as doing nothing (0.005 = 0.5%).
    public var idleCPUShare: Double = 0.005
    public var nudgeEnabled = true
    /// Minutes after local midnight (18:00 by default).
    public var nudgeMinute = 18 * 60
    public var hotKey: HotKeyChoice = .controlOptionP
    /// Seconds between SIGTERM and SIGKILL when stopping.
    public var stopGraceSeconds: Double = 5

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field is optional on disk, so new settings never break old files.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        idleHours = (try? c.decodeIfPresent(Double.self, forKey: .idleHours)) ?? d.idleHours
        oldHours = (try? c.decodeIfPresent(Double.self, forKey: .oldHours)) ?? d.oldHours
        idleCPUShare = (try? c.decodeIfPresent(Double.self, forKey: .idleCPUShare)) ?? d.idleCPUShare
        nudgeEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .nudgeEnabled)) ?? d.nudgeEnabled
        nudgeMinute = (try? c.decodeIfPresent(Int.self, forKey: .nudgeMinute)) ?? d.nudgeMinute
        hotKey = (try? c.decodeIfPresent(HotKeyChoice.self, forKey: .hotKey)) ?? d.hotKey
        stopGraceSeconds = (try? c.decodeIfPresent(Double.self, forKey: .stopGraceSeconds)) ?? d.stopGraceSeconds
        clamp()
    }

    /// Keeps hand-edited values sane.
    public mutating func clamp() {
        idleHours = min(max(idleHours, 0.25), 24 * 7)
        oldHours = min(max(oldHours, 1), 24 * 30)
        idleCPUShare = min(max(idleCPUShare, 0.0001), 0.5)
        nudgeMinute = min(max(nudgeMinute, 0), 24 * 60 - 1)
        stopGraceSeconds = min(max(stopGraceSeconds, 1), 60)
    }

    public var idleWindow: TimeInterval { idleHours * 3600 }
    public var oldAge: TimeInterval { oldHours * 3600 }
}
