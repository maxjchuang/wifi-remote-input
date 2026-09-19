// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SystemConfiguration

public struct DeviceRecord: Codable, Equatable, Identifiable {
    public var id: String { fingerprint }
    public var enterMode: String? = nil
    public var name: String
    public var address: String
    public var fingerprint: String
    public init(name: String, address: String, fingerprint: String) {
        self.name = name; self.address = address; self.fingerprint = fingerprint
    }
}

public enum DeviceNames {
    public static func automaticComputerName(systemName: String?, modelName: String) -> String {
        let name = cleaned(systemName ?? "", fallback: "")
        // Enterprise Macs often use an opaque asset/serial code as their computer name.
        let opaque = name.range(of: "^[A-Z0-9]{8,}$", options: .regularExpression) != nil && name.rangeOfCharacter(from: .decimalDigits) != nil
        return name.isEmpty || opaque ? cleaned(modelName, fallback: "Mac") : name
    }
    private static let hardwareName: String = {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json", "-detailLevel", "mini", "-timeout", "3"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hardware = json["SPHardwareDataType"] as? [[String: Any]],
                  let name = hardware.first?["machine_name"] as? String else { return "Mac" }
            return name
        } catch { return "Mac" }
    }()
    public static func computerName() -> String {
        let systemName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        let name = automaticComputerName(systemName: systemName, modelName: "")
        return name == "Mac" ? automaticComputerName(systemName: systemName, modelName: hardwareName) : name
    }

    public static func cleaned(_ value: String, fallback: String) -> String {
        let clean = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }
        let text = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        // Use UTF-16 units to match Android validation (including emoji names).
        var result = ""
        for character in text {
            guard (result + String(character)).utf16.count <= 80 else { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
    }
}

/// Freeze recipients at input time. Never silently omit an unavailable target.
public struct InputTargets {
    public var selected: String
    public var broadcast: Set<String>?
    public init(selected: String, broadcast: Set<String>? = nil) { self.selected = selected; self.broadcast = broadcast }
    public var ids: Set<String> { broadcast ?? [selected] }
    public func ready(available: Set<String>) -> Bool { !ids.isEmpty && ids.isSubset(of: available) }
}
