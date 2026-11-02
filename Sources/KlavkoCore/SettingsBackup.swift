import Foundation

/// All of Klavko's settings in one file, to take to a new Mac or give to a colleague. Plain JSON, readable by eye.
/// The user's rules (key remapping, words and apps Klavko leaves alone, word replacements, the voice input
/// vocabulary) are added to what is there, a rule for the same key or word taken from the file; every other
/// setting is taken from the file as it is.
public struct SettingsBackup: Codable, Equatable, Sendable {
    public static let format = 1

    public var keyRemaps: [KeyRemap]
    public var exceptions: [String]
    public var excludedApps: [String]
    public var replacements: [Replacement]
    public var voiceVocabulary: [Replacement]
    /// The other settings, by their UserDefaults key.
    public var preferences: [String: JSONValue] = [:]
    public var launchAtLogin: Bool?
    /// Only when the user chose to put it in: it is a secret.
    public var googleKey: String?
    /// "mac", or "windows" for a file of Klavko for Windows: only its words (exceptions, word replacements,
    /// the voice vocabulary) mean the same here, so only they are read.
    public private(set) var system = "mac"
    public var isFromThisSystem: Bool { system == "mac" }

    public init(keyRemaps: [KeyRemap] = [], exceptions: [String] = [], excludedApps: [String] = [],
                replacements: [Replacement] = [], voiceVocabulary: [Replacement] = []) {
        self.keyRemaps = keyRemaps
        self.exceptions = exceptions
        self.excludedApps = excludedApps
        self.replacements = replacements
        self.voiceVocabulary = voiceVocabulary
    }

    public var isEmpty: Bool {
        keyRemaps.isEmpty && exceptions.isEmpty && excludedApps.isEmpty && replacements.isEmpty && voiceVocabulary.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case app, format, system, keyRemaps, exceptions, excludedApps, replacements, voiceVocabulary, preferences, launchAtLogin, googleKey
    }

    public enum Failure: Error { case notKlavko, newerFormat }

    /// What a file of a later Klavko holds beyond this one is left out; a list it lacks is empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? c.decode(String.self, forKey: .app)) == "Klavko" else { throw Failure.notKlavko }
        guard (try c.decodeIfPresent(Int.self, forKey: .format) ?? 1) <= Self.format else { throw Failure.newerFormat }
        system = (try? c.decodeIfPresent(String.self, forKey: .system)) ?? "mac"
        exceptions = (try? c.decodeIfPresent([String].self, forKey: .exceptions)) ?? []
        replacements = (try? c.decodeIfPresent([Replacement].self, forKey: .replacements)) ?? []
        voiceVocabulary = (try? c.decodeIfPresent([Replacement].self, forKey: .voiceVocabulary)) ?? []
        guard system == "mac" else {
            keyRemaps = []
            excludedApps = []
            return
        }
        keyRemaps = try c.decodeIfPresent([KeyRemap].self, forKey: .keyRemaps) ?? []
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
        preferences = try c.decodeIfPresent([String: JSONValue].self, forKey: .preferences) ?? [:]
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
        googleKey = try c.decodeIfPresent(String.self, forKey: .googleKey)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("Klavko", forKey: .app)
        try c.encode(Self.format, forKey: .format)
        try c.encode(system, forKey: .system)
        try c.encode(keyRemaps, forKey: .keyRemaps)
        try c.encode(exceptions, forKey: .exceptions)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(replacements, forKey: .replacements)
        try c.encode(voiceVocabulary, forKey: .voiceVocabulary)
        try c.encode(preferences, forKey: .preferences)
        try c.encodeIfPresent(launchAtLogin, forKey: .launchAtLogin)
        try c.encodeIfPresent(googleKey, forKey: .googleKey)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func read(_ data: Data) throws -> SettingsBackup {
        try JSONDecoder().decode(SettingsBackup.self, from: data)
    }

    /// These rules with the rules of `restored` added (the other settings are left to the caller): how many
    /// rules were new or changed.
    public func merged(with restored: SettingsBackup) -> (SettingsBackup, changes: Int) {
        var result = self
        var changes = 0
        for rule in restored.keyRemaps where !keyRemaps.contains(where: { $0.from == rule.from && $0.to == rule.to }) {
            result.keyRemaps = KeyRemapping.adding(KeyRemap(from: rule.from, to: rule.to), to: result.keyRemaps)
            changes += 1
        }
        for input in restored.exceptions {
            let word = TextRules.coreWord(input.trimmingCharacters(in: .whitespacesAndNewlines)).lowercased()
            guard !word.isEmpty, !result.exceptions.contains(word) else { continue }
            result.exceptions.append(word)
            changes += 1
        }
        result.exceptions.sort()
        for app in restored.excludedApps where !app.isEmpty && !result.excludedApps.contains(app) {
            result.excludedApps.append(app)
            changes += 1
        }
        for rule in restored.replacements where !rule.from.isEmpty && !rule.to.isEmpty && !result.replacements.contains(rule) {
            result.replacements = result.replacements.filter { $0.from != rule.from } + [rule]
            changes += 1
        }
        for rule in restored.voiceVocabulary where !rule.from.isEmpty && !rule.to.isEmpty && !result.voiceVocabulary.contains(rule) {
            result.voiceVocabulary = result.voiceVocabulary.filter { $0.from.lowercased() != rule.from.lowercased() } + [rule]
            changes += 1
        }
        return (result, changes)
    }
}

/// A UserDefaults value as JSON. Data that holds JSON (the lists Klavko keeps encoded) is written out as that
/// JSON, so the file stays readable: {"$json": …}; other data as {"$data": "base64"}, a date as {"$date": seconds}.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init?(defaultsValue value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let date as Date:
            self = .object(["$date": .number(date.timeIntervalSince1970)])
        case let data as Data:
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let json = JSONValue(defaultsValue: object) {
                self = .object(["$json": json])
            } else {
                self = .object(["$data": .string(data.base64EncodedString())])
            }
        case let array as [Any]:
            let items = array.compactMap(JSONValue.init(defaultsValue:))
            guard items.count == array.count else { return nil }
            self = .array(items)
        case let dictionary as [String: Any]:
            var items: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                guard let value = JSONValue(defaultsValue: item) else { return nil }
                items[key] = value
            }
            self = .object(items)
        default:
            return nil
        }
    }

    /// The value to put back into UserDefaults.
    public var defaultsValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): return value
        case .array(let items): return items.compactMap(\.defaultsValue)
        case .object(let items):
            if items.count == 1, let json = items["$json"] {
                return json.jsonObject.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            }
            if items.count == 1, case .string(let base64)? = items["$data"] { return Data(base64Encoded: base64) }
            if items.count == 1, case .number(let seconds)? = items["$date"] { return Date(timeIntervalSince1970: seconds) }
            return items.compactMapValues(\.defaultsValue)
        }
    }

    /// For JSONSerialization: numbers and booleans as they were.
    private var jsonObject: Any? {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) as Any : value
        case .string(let value): return value
        case .array(let items): return items.compactMap(\.jsonObject)
        case .object(let items): return items.compactMapValues(\.jsonObject)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}
