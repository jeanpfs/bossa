import Foundation

// MARK: - Wire types (JSON from the Rust core, snake_case)

struct ModeInfo: Codable, Identifiable, Equatable {
    var index: Int
    var name: String
    var favorite: Bool
    var userConfigurable: Bool
    var userConfigured: Bool
    var cncMutable: Bool
    var spatialMutable: Bool
    /// 0 = full noise cancelling ... 10 = full awareness.
    var cncLevel: Int
    /// 0 off, 1 fixed, 2 head-tracked.
    var spatialAudio: Int
    var id: Int { index }
}

struct ModeSettingsView: Codable, Equatable {
    var cncLevel: Int
    var spatialAudio: Int
}

struct Multipoint: Codable, Equatable {
    var enabled: Bool
    var supported: Bool
}

struct EqBand: Codable, Equatable {
    var id: Int
    var min: Int
    var max: Int
    var current: Int
}

struct DeviceState: Codable, Equatable {
    var status: String = "searching"      // searching | connecting | connected | error
    var message: String?
    var name: String?
    var firmware: String?
    var mac: String?
    var battery: Int?
    var remainingMinutes: Int?
    var modes: [ModeInfo] = []
    var settings: ModeSettingsView?
    var multipoint: Multipoint?
    var mode: Int?
    var shortcutMode: Int?
    var shortcutOptions: [Int] = []
    var autoPause: Bool?
    var captouchFlag: Bool?
    var eq: [EqBand] = []

    var connected: Bool { status == "connected" }
}

struct VolumeInfo: Codable {
    var available: Bool
    var level: Int?
}

struct PrefsView: Codable {
    var autostart: Bool
    var autostartSupported: Bool
    var lowBatteryAlerts: Bool
}

// MARK: - Events

enum CoreEvent {
    case state(DeviceState)
    case alert(kind: String, name: String?, level: Int)

    static func parse(_ line: String) -> CoreEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "state":
            guard let st = obj["state"], let d = try? JSONSerialization.data(withJSONObject: st) else { return nil }
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            return (try? dec.decode(DeviceState.self, from: d)).map(CoreEvent.state)
        case "alert":
            return .alert(kind: obj["kind"] as? String ?? "low", name: obj["name"] as? String, level: obj["level"] as? Int ?? 0)
        default:
            return nil
        }
    }
}

// MARK: - Bridge to the Rust core (C ABI in core/include/bose_core.h)

enum Core {
    nonisolated(unsafe) static var onEvent: (@Sendable (String) -> Void)?

    static func start(_ handler: @escaping @Sendable (String) -> Void) {
        onEvent = handler
        bose_start({ _, json in
            guard let json else { return }
            Core.onEvent?(String(cString: json))
        }, nil)
    }

    @discardableResult
    static func command(_ obj: [String: Any]) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return false }
        return bose_command(s) == 0
    }

    /// Synchronous request; call off the main thread (volume touches CoreAudio, prefs touch disk).
    static func request<T: Decodable>(_ obj: [String: Any], as: T.Type = T.self) throws -> T {
        let raw = try rawRequest(obj)
        guard let ok = raw["ok"] else { throw CoreError(raw["error"] as? String ?? "invalid response") }
        let d = try JSONSerialization.data(withJSONObject: ok, options: [.fragmentsAllowed])
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    static func send(_ obj: [String: Any]) throws {
        let raw = try rawRequest(obj)
        if let e = raw["error"] as? String { throw CoreError(e) }
    }

    private static func rawRequest(_ obj: [String: Any]) throws -> [String: Any] {
        let d = try JSONSerialization.data(withJSONObject: obj)
        guard let s = String(data: d, encoding: .utf8), let p = bose_request(s) else { throw CoreError("core unavailable") }
        defer { bose_free(p) }
        guard let out = try JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any] else { throw CoreError("invalid response") }
        return out
    }
}

struct CoreError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// `Decodable` placeholder for requests that answer `{"ok":null}`.
struct Empty: Decodable {}
