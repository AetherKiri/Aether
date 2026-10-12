import AppKit
import Foundation

/// Session accumulation and the dashboard statistics migrated from the Godot
/// shell's `_dashboard_stats()` / `_add_play_duration`.
enum PlayStatsTests {
    static func run(root: URL) throws {
        try legacyIndexCompatibility(root: root)
        durationFormatting()
        greetings()
        statsAlgorithm()
        try libraryAccumulation(root: root)
        print("PASS: legacy index compatibility, duration/greeting formatting, Godot dashboard statistics and capped play-time accumulation")
    }

    /// Old indexes have neither playDurationSeconds nor a last-played stamp.
    private static func legacyIndexCompatibility(root: URL) throws {
        let library = GameLibrary(root: root.appendingPathComponent("playstats-legacy"))
        let id = UUID()
        let legacy: [[String: Any]] = [[
            "id": id.uuidString,
            "title": "Legacy",
            "directory": id.uuidString,
            "sourcePath": "/fixtures/legacy",
            "importedAt": Date().timeIntervalSinceReferenceDate,
        ]]
        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy).write(to: library.root.appendingPathComponent("library.json"))
        let loaded = try library.load()
        precondition(loaded.count == 1)
        precondition(loaded[0].playDurationSeconds == 0 && loaded[0].lastPlayedAt == nil)
    }

    private static func durationFormatting() {
        precondition(PlayStats.duration(0) == "0m")
        precondition(PlayStats.duration(59) == "0m")
        precondition(PlayStats.duration(60) == "1m")
        precondition(PlayStats.duration(3599) == "59m")
        precondition(PlayStats.duration(3600) == "1h")
        precondition(PlayStats.duration(3660) == "1h 1m")
        precondition(PlayStats.duration(7200) == "2h")
        precondition(PlayStats.maximumSessionSeconds == 86_400)
    }

    private static func greetings() {
        precondition(PlayStats.greetingKey(hour: 4) == "dashGreetingNight")
        precondition(PlayStats.greetingKey(hour: 5) == "dashGreetingMorning")
        precondition(PlayStats.greetingKey(hour: 11) == "dashGreetingMorning")
        precondition(PlayStats.greetingKey(hour: 12) == "dashGreetingAfternoon")
        precondition(PlayStats.greetingKey(hour: 17) == "dashGreetingAfternoon")
        precondition(PlayStats.greetingKey(hour: 18) == "dashGreetingEvening")
        precondition(PlayStats.greetingKey(hour: 23) == "dashGreetingEvening")
    }

    private static func statsAlgorithm() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func game(_ title: String, seconds: Int, daysAgo: Int?) -> LibraryGame {
            let id = UUID()
            var entry = LibraryGame(id: id, title: title, directory: id.uuidString, sourcePath: "/fixtures/" + title,
                                    importedAt: now, lastPlayedAt: daysAgo.map { now.addingTimeInterval(Double(-$0) * 86_400) })
            entry.playDurationSeconds = seconds
            return entry
        }
        let games = [
            game("A", seconds: 10_800, daysAgo: 1),
            game("B", seconds: 30, daysAgo: 3),
            game("C", seconds: 0, daysAgo: nil),
            game("D", seconds: 5_400, daysAgo: 10),
            game("E", seconds: 7_200, daysAgo: nil),
        ]
        let stats = PlayStats(games: games, now: now, calendar: calendar)
        precondition(stats.gamesCount == 5)
        precondition(stats.totalSeconds == 23_430)
        precondition(stats.playedCount == 4, "games with time or a last-played stamp count as played")
        precondition(stats.weekCount == 2, "only the last seven days count as active")
        precondition(stats.ranked.map(\.title) == ["A", "E", "D"], "ranked needs >= 60s, duration desc, top 5")
        precondition(stats.recent.map(\.title) == ["A", "B", "D"], "recent is by last played, top 5")
        precondition(stats.spotlight?.title == "A")
        precondition(stats.averageSeconds == 5_820, "Godot truncates the average to whole minutes: \(stats.averageSeconds)")
        precondition(stats.activeDays == 2)
        precondition(stats.dayTrail[5] == ["A"] && stats.dayTrail[3] == ["B"])
        precondition(stats.dayTrail[6].isEmpty && stats.dayTrail[0].isEmpty)
        precondition(stats.totalHoursWhole == 6 && stats.totalMinutesRemainder == 30)
        precondition(stats.nextMilestoneHours == 10, "next milestone above 6.5h")
        precondition(abs(stats.milestoneProgress - 0.650833) < 0.001)
        precondition(abs(stats.libraryProgress - 0.8) < 0.0001)
        precondition(abs(stats.daysProgress - 2.0 / 7.0) < 0.0001)
        // An empty library must not divide by zero or invent a milestone.
        let empty = PlayStats(games: [], now: now, calendar: calendar)
        precondition(empty.gamesCount == 0 && empty.totalSeconds == 0 && empty.isEmpty)
        precondition(empty.libraryProgress == 0 && empty.activeDays == 0 && empty.averageSeconds == 0)
        precondition(empty.nextMilestoneHours == 1 && empty.milestoneProgress == 0)
    }

    private static func libraryAccumulation(root: URL) throws {
        let library = GameLibrary(root: root.appendingPathComponent("playstats-accumulate"))
        let demo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("demos/aetherkiri-kag3/data")
        let game = try library.importDirectory(demo, existing: [], external: true).imported
        var games = [game]
        games = try library.addPlayDuration(120, to: game.id, existing: games)
        games = try library.addPlayDuration(30, to: game.id, existing: games)
        games = try library.addPlayDuration(0, to: game.id, existing: games)
        games = try library.addPlayDuration(-5, to: game.id, existing: games)
        precondition(games[0].playDurationSeconds == 150)
        // A single session contribution is capped at one day, like Godot.
        games = try library.addPlayDuration(90_000, to: game.id, existing: games)
        precondition(games[0].playDurationSeconds == 150 + 86_400)
        let stored = try library.load()
        precondition(stored[0].playDurationSeconds == 150 + 86_400)
        do {
            _ = try library.addPlayDuration(10, to: UUID(), existing: games)
            preconditionFailure("unknown entry must not be created")
        } catch {}
    }
}
