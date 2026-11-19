import Combine
import SwiftUI

public enum Defaults {
    public struct Key<Value> { let name: String }
    public struct Change<Value> { public let newValue: Value }
    private static var values = ["enableLyrics": false, "lyricsTranslationEnabled": false]
    private static var streams: [String: PassthroughSubject<Change<Bool>, Never>] = [:]

    public static subscript(key: Key<Bool>) -> Bool {
        get { values[key.name] ?? false }
        set {
            values[key.name] = newValue
            streams[key.name]?.send(Change(newValue: newValue))
        }
    }

    public static func publisher(_ key: Key<Bool>) -> AnyPublisher<Change<Bool>, Never> {
        let subject = streams[key.name] ?? PassthroughSubject<Change<Bool>, Never>()
        streams[key.name] = subject
        return subject.prepend(Change(newValue: values[key.name] ?? false)).eraseToAnyPublisher()
    }

    public static subscript(key: Key<Int>) -> Int { 0 }
}

public extension Defaults.Key where Value == Bool {
    static let enableLyrics = Self(name: "enableLyrics")
    static let lyricsTranslationEnabled = Self(name: "lyricsTranslationEnabled")
}

public extension Defaults.Key where Value == Int {
    static let lyricsVisibleLines = Self(name: "lyricsVisibleLines")
}

@propertyWrapper public struct Default: DynamicProperty {
    private let key: Defaults.Key<Bool>
    public init(_ key: Defaults.Key<Bool>) { self.key = key }
    public var wrappedValue: Bool { Defaults[key] }
}
