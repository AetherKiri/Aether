import Foundation

/// Play statistics migrated from the Godot shell's `_dashboard_stats()`.
///
/// Only `playDurationSeconds` and `lastPlayedAt` are persisted per game; every
/// dashboard number is derived, so a stale cache cannot drift from the index.
/// `lastPlayedAt` is a single timestamp: the seven-day trail is an activity
/// trail, not a calendar history of exact sessions.
struct PlayStats {
    struct Entry: Equatable {
        let id: UUID
        let title: String
        let seconds: Int
        let lastPlayed: Date?
    }

    /// Godot `DASH_MILESTONES`, in hours.
    static let milestones = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
    /// Godot clamps a single session contribution to one day.
    static let maximumSessionSeconds = 86_400
    static let weekWindow: TimeInterval = 7 * 86_400

    let gamesCount: Int
    let totalSeconds: Int
    let playedCount: Int
    let weekCount: Int
    let averageSeconds: Int
    let ranked: [Entry]
    let recent: [Entry]
    /// Seven buckets ending today (index 6); each holds the titles opened that
    /// local day. Godot parity for `_dashboard_stats()["days"]`.
    let dayTrail: [[String]]
    let activeDays: Int

    var spotlight: Entry? { recent.first }
    var isEmpty: Bool { recent.isEmpty && totalSeconds == 0 }

    init(games: [LibraryGame], now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        var total = 0
        var played = 0
        var week = 0
        var ranked: [Entry] = []
        var recent: [Entry] = []
        var days = [[String]](repeating: [], count: 7)
        for game in games {
            let seconds = max(0, game.playDurationSeconds)
            let lastPlayed = game.lastPlayedAt
            total += seconds
            if seconds > 0 || lastPlayed != nil { played += 1 }
            if let lastPlayed, now.timeIntervalSince(lastPlayed) < Self.weekWindow { week += 1 }
            let entry = Entry(id: game.id, title: game.displayTitle, seconds: seconds, lastPlayed: lastPlayed)
            if seconds >= 60 { ranked.append(entry) }
            if let lastPlayed {
                recent.append(entry)
                let day = calendar.startOfDay(for: lastPlayed)
                let offset = calendar.dateComponents([.day], from: day, to: today).day ?? 0
                if offset >= 0, offset < days.count { days[days.count - 1 - offset].append(game.displayTitle) }
            }
        }
        // Deterministic ordering: Godot ranks by duration and recency only.
        ranked.sort { left, right in
            left.seconds == right.seconds ? left.title < right.title : left.seconds > right.seconds
        }
        recent.sort { left, right in
            let leftTime = left.lastPlayed ?? .distantPast
            let rightTime = right.lastPlayed ?? .distantPast
            return leftTime == rightTime ? left.title < right.title : leftTime > rightTime
        }
        gamesCount = games.count
        totalSeconds = total
        playedCount = played
        weekCount = week
        // Godot truncates the average to whole minutes before formatting.
        averageSeconds = played > 0 ? (total / played / 60) * 60 : 0
        self.ranked = Array(ranked.prefix(5))
        self.recent = Array(recent.prefix(5))
        dayTrail = days
        activeDays = days.filter { !$0.isEmpty }.count
    }

    var totalHours: Double { Double(totalSeconds) / 3600 }
    var totalHoursWhole: Int { totalSeconds / 3600 }
    var totalMinutesRemainder: Int { (totalSeconds % 3600) / 60 }
    var averageMinutes: Int { averageSeconds / 60 }

    var nextMilestoneHours: Int {
        for milestone in Self.milestones where totalHours < Double(milestone) { return milestone }
        return Self.milestones.last ?? 1
    }

    var milestoneProgress: Double {
        min(1, max(0, totalHours / Double(nextMilestoneHours)))
    }

    var libraryProgress: Double {
        gamesCount > 0 ? min(1, max(0, Double(playedCount) / Double(gamesCount))) : 0
    }

    var daysProgress: Double {
        min(1, max(0, Double(activeDays) / Double(dayTrail.count)))
    }

    /// Godot `_format_play_duration`: 0m / %dm / %dh / %dh %dm.
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "0m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// Godot `_dash_greeting_key()`, by local hour.
    static func greetingKey(hour: Int) -> String {
        if hour < 5 { return "dashGreetingNight" }
        if hour < 12 { return "dashGreetingMorning" }
        if hour < 18 { return "dashGreetingAfternoon" }
        return "dashGreetingEvening"
    }
}
