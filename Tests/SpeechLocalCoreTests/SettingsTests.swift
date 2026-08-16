import Testing
import Foundation
@testable import SpeechLocalCore

private func freshStore() -> SettingsStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-settings-\(UUID().uuidString).json")
    return SettingsStore(url: url)
}

// MARK: - Defaults

@Test func defaultsAreSensible() {
    let settings = Settings.default
    #expect(settings.lightTouchKey == .rightOption)
    #expect(settings.fullRewriteKey == .rightCommand)
    #expect(settings.commaPolicy == .sparse)
    #expect(settings.isValid)
}

@Test func freshStoreReturnsDefaults() {
    #expect(freshStore().current == .default)
}

// MARK: - Hotkey conflicts

@Test func distinctHotkeysAreValid() {
    #expect(Settings.default.isValid)
}

@Test func identicalHotkeysAreInvalid() {
    var settings = Settings.default
    settings.fullRewriteKey = settings.lightTouchKey
    #expect(!settings.isValid)
}

@Test func conflictMovesTheOtherBinding() {
    // Binding light-touch to the key rewrite already uses must not make one
    // gesture unreachable; the most recent intent wins and the other moves.
    var settings = Settings.default
    settings.lightTouchKey = .rightCommand      // collides with fullRewriteKey
    let resolved = settings.resolvingConflicts(changed: \.lightTouchKey)
    #expect(resolved.lightTouchKey == .rightCommand, "the changed key is kept")
    #expect(resolved.fullRewriteKey != .rightCommand)
    #expect(resolved.isValid)
}

@Test func resolvingAValidSettingsChangesNothing() {
    let settings = Settings.default
    #expect(settings.resolvingConflicts(changed: \.lightTouchKey) == settings)
}

@Test func everyHotkeyChoiceHasADistinctKeyCode() {
    let codes = Set(HotkeyChoice.allCases.map(\.keyCode))
    #expect(codes.count == HotkeyChoice.allCases.count)
}

// MARK: - Persistence

@Test func changesPersistToDisk() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-persist-\(UUID().uuidString).json")
    let first = SettingsStore(url: url)
    first.update {
        $0.commaPolicy = .tidy
        $0.aliases = ["nda": "NDA"]
        $0.playSounds = false
    }

    // A new instance reading the same file is what happens on next launch.
    let second = SettingsStore(url: url)
    #expect(second.current.commaPolicy == .tidy)
    #expect(second.current.aliases == ["nda": "NDA"])
    #expect(second.current.playSounds == false)
}

@Test func corruptFileFallsBackToDefaults() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-corrupt-\(UUID().uuidString).json")
    try? "this is not json".write(to: url, atomically: true, encoding: .utf8)
    // Must not crash or refuse to launch.
    #expect(SettingsStore(url: url).current == .default)
}

@Test func missingFieldsDecodeToDefaults() throws {
    // An older settings file lacking fields added later must not wipe the rest
    // of the user's configuration.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-partial-\(UUID().uuidString).json")
    try #"{"commaPolicy":"tidy"}"#.write(to: url, atomically: true, encoding: .utf8)

    let settings = SettingsStore(url: url).current
    #expect(settings.commaPolicy == .tidy, "the present field is honoured")
    #expect(settings.lightTouchKey == Settings.default.lightTouchKey)
    #expect(settings.playSounds == Settings.default.playSounds)
}

// MARK: - Vocabulary bridge

@Test func aliasesBecomeAVocabulary() {
    var settings = Settings.default
    settings.aliases = ["kill annie": "Kilanii"]
    let matcher = VocabularyMatcher()
    #expect(matcher.apply(settings.vocabulary, to: "ask kill annie") == "ask Kilanii")
}

@Test func emptyAliasesGiveAnEmptyVocabulary() {
    #expect(Settings.default.vocabulary.aliases.isEmpty)
}
