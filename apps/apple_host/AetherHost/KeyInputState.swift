import Foundation

struct KeyTransition: Equatable {
    let pressed: Bool
    let key: Int32
    let modifiers: Int32
    let unicode: UInt32
}

// The engine sees one down/up pair even if hardware and on-screen keys overlap.
struct KeyInputState {
    enum Source: Hashable { case physical, virtual }
    private var owners: [Int32: Set<Source>] = [:]

    mutating func set(_ source: Source, key: Int32, pressed: Bool, modifiers: Int32 = 0, unicode: UInt32 = 0) -> [KeyTransition] {
        guard key != 0 else { return [] }
        var sources = owners[key] ?? []
        if pressed {
            let wasPressed = !sources.isEmpty
            sources.insert(source); owners[key] = sources
            if !wasPressed || (source == .physical && modifiers & 0x80 != 0) {
                return [KeyTransition(pressed: true, key: key, modifiers: modifiers, unicode: unicode)]
            }
        } else if sources.remove(source) != nil {
            if sources.isEmpty {
                owners.removeValue(forKey: key)
                return [KeyTransition(pressed: false, key: key, modifiers: modifiers, unicode: 0)]
            }
            owners[key] = sources
        }
        return []
    }

    mutating func release(_ source: Source) -> [KeyTransition] {
        owners.keys.sorted().flatMap { set(source, key: $0, pressed: false) }
    }
    mutating func releaseAll() -> [KeyTransition] {
        let keys = owners.keys.sorted()
        owners.removeAll()
        return keys.map { KeyTransition(pressed: false, key: $0, modifiers: 0, unicode: 0) }
    }
}

enum GameTextInput {
    static let maximumScalars = 2048
    static func scalars(_ text: String) -> [UInt32] {
        Array(text.unicodeScalars.lazy.map(\.value).filter { $0 != 0 && $0 != 10 && $0 != 13 }.prefix(maximumScalars))
    }
}
