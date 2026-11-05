import Darwin
import Foundation

/// How hard pressed the system is for memory, as the kernel says it (`kern.memorystatus_vm_pressure_level`, which Activity
/// Monitor's memory pressure graph shows): green, yellow, red. The text reader asks before it loads the VLM pack, whose
/// reading takes 2.6 GB (Docs/ocr.md › The VLM pack): with the system already pressed, the tables stay as Vision read
/// them rather than push other apps' memory out to disk.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    /// The level now; normal when the kernel doesn't say.
    public static func current() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    /// A level by name, as a test or a debug hook names it: "normal", "warning", or "critical".
    public init?(name: String) {
        switch name {
        case "normal": self = .normal
        case "warning": self = .warning
        case "critical": self = .critical
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Said by name (`name`, "pressure": "warning" in a text reader's job), not by the kernel's number for it.
extension MemoryPressure: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let pressure = MemoryPressure(name: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "No memory pressure is called \(name)")
        }
        self = pressure
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}
