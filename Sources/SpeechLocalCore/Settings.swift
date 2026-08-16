import Foundation

/// The modifier keys offered as hotkeys.
///
/// Restricted to right-hand modifiers and Fn on purpose: they are rarely used
/// alone, so binding them does not shadow an existing shortcut. Arbitrary key
/// capture would let the user bind something that breaks their own typing.
public enum HotkeyChoice: String, Codable, Sendable, CaseIterable, Equatable {
    case rightOption, rightCommand, rightControl, fn

    public var displayName: String {
        switch self {
        case .rightOption:  return "Right Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .fn:           return "Fn"
        }
    }

    public var keyCode: UInt16 {
        switch self {
        case .rightOption:  return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn:           return 63
        }
    }
}

public enum CommaChoice: String, Codable, Sendable, CaseIterable, Equatable {
    /// Keep the recognizer's commas; repair only mechanically broken ones.
    case tidy
    /// Drop commas that do not precede a clause marker or sit inside a list.
    case sparse

    public var displayName: String {
        switch self {
        case .tidy:   return "Keep all punctuation"
        case .sparse: return "Only grammatical commas"
        }
    }
}

public struct Settings: Codable, Sendable, Equatable {
    public var lightTouchKey: HotkeyChoice
    public var fullRewriteKey: HotkeyChoice
    public var commaPolicy: CommaChoice
    /// Spoken form (lowercased) → written form.
    public var aliases: [String: String]
    public var launchAtLogin: Bool
    public var locale: String
    public var playSounds: Bool
    public var keepHistory: Bool

    public static let `default` = Settings(
        lightTouchKey: .rightOption,
        fullRewriteKey: .rightCommand,
        commaPolicy: .sparse,
        aliases: [:],
        launchAtLogin: false,
        locale: "en-US",
        playSounds: true,
        keepHistory: true
    )

    public init(
        lightTouchKey: HotkeyChoice,
        fullRewriteKey: HotkeyChoice,
        commaPolicy: CommaChoice,
        aliases: [String: String],
        launchAtLogin: Bool,
        locale: String,
        playSounds: Bool,
        keepHistory: Bool
    ) {
        self.lightTouchKey = lightTouchKey
        self.fullRewriteKey = fullRewriteKey
        self.commaPolicy = commaPolicy
        self.aliases = aliases
        self.launchAtLogin = launchAtLogin
        self.locale = locale
        self.playSounds = playSounds
        self.keepHistory = keepHistory
    }

    /// Older files may lack fields added later; every key decodes with a
    /// fallback so an upgrade never wipes the user's configuration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings.default
        lightTouchKey = try container.decodeIfPresent(
            HotkeyChoice.self, forKey: .lightTouchKey) ?? fallback.lightTouchKey
        fullRewriteKey = try container.decodeIfPresent(
            HotkeyChoice.self, forKey: .fullRewriteKey) ?? fallback.fullRewriteKey
        commaPolicy = try container.decodeIfPresent(
            CommaChoice.self, forKey: .commaPolicy) ?? fallback.commaPolicy
        aliases = try container.decodeIfPresent(
            [String: String].self, forKey: .aliases) ?? fallback.aliases
        launchAtLogin = try container.decodeIfPresent(
            Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
        locale = try container.decodeIfPresent(
            String.self, forKey: .locale) ?? fallback.locale
        playSounds = try container.decodeIfPresent(
            Bool.self, forKey: .playSounds) ?? fallback.playSounds
        keepHistory = try container.decodeIfPresent(
            Bool.self, forKey: .keepHistory) ?? fallback.keepHistory
    }

    /// The two hotkeys must differ, or one gesture becomes unreachable.
    public var isValid: Bool { lightTouchKey != fullRewriteKey }

    /// Returns a valid copy, moving the conflicting binding rather than
    /// rejecting the change — the user's most recent intent wins.
    public func resolvingConflicts(changed: WritableKeyPath<Settings, HotkeyChoice>) -> Settings {
        guard !isValid else { return self }
        var copy = self
        let taken = copy[keyPath: changed]
        let other: WritableKeyPath<Settings, HotkeyChoice> =
            changed == \.lightTouchKey ? \.fullRewriteKey : \.lightTouchKey
        copy[keyPath: other] = HotkeyChoice.allCases.first { $0 != taken } ?? .fn
        return copy
    }

    public var vocabulary: Vocabulary { Vocabulary(aliases: aliases) }
}

/// Loads and saves `Settings` as JSON.
public final class SettingsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var cached: Settings

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechLocal/settings.json")
        self.cached = Self.load(from: self.url)
    }

    public var current: Settings {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    @discardableResult
    public func update(_ transform: (inout Settings) -> Void) -> Settings {
        lock.lock()
        var next = cached
        transform(&next)
        cached = next
        lock.unlock()
        save(next)
        return next
    }

    /// Static and pure so it can run from `init`.
    private static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return decoded
    }

    private func save(_ settings: Settings) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
