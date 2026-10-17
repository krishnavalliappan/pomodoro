import PomodoroCore
import SwiftUI

/// Today in three numbers, the last seven days as bars, and the way into the full Stats view.
///
/// Reads `model.today`, which a logged session or a new day refreshes; the tick never does.
struct PopoverStatsTab: View {
    static let dayCount = 7
    static let barHeight: CGFloat = 52

    var model: AppModel
    var openStats: @MainActor () -> Void

    @State private var days: [DayFocus]

    init(model: AppModel, openStats: @escaping @MainActor () -> Void) {
        self.model = model
        self.openStats = openStats
        // Read up front, so the first frame (and every snapshot) already has its bars.
        _days = State(initialValue: Self.recentDays(model))
    }

    private var summary: TodaySummary { model.today }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today")
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                StatTile(value: Stats.durationText(summary.focusedSeconds), label: "Focus")
                StatTile(value: "\(summary.completedPomodoros)", label: "Pomodoros")
                StatTile(value: "\(summary.streak.current)", label: "Day streak")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(summary))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last 7 days")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Stats.durationText(days.reduce(0) { $0 + $1.focusedSeconds }))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Sparkline(days: days, today: summary.day, calendar: model.database.calendar, height: Self.barHeight)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PopoverStyle.surface))
            Button(action: openStats) {
                Label("Open Stats", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(SoftButtonStyle())
        }
        .onChange(of: summary) { days = Self.recentDays(model) }
    }

    private static func recentDays(_ model: AppModel) -> [DayFocus] {
        (try? model.database.stats.recentDays(dayCount, now: model.clock.now)) ?? []
    }

    static func accessibilityText(_ summary: TodaySummary) -> String {
        let count = summary.completedPomodoros
        var text = "Today: \(Stats.durationText(summary.focusedSeconds)) of focus, \(count == 1 ? "1 pomodoro" : "\(count) pomodoros")"
        if summary.streak.current > 0 { text += ", \(summary.streak.current)-day streak" }
        return text
    }
}

private struct StatTile: View {
    var value: String
    var label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PopoverStyle.surface))
    }
}

/// One bar per day, scaled to the busiest; today in the accent. Plain shapes rather than
/// Charts, so a bar is always exactly the height its share gives it.
private struct Sparkline: View {
    var days: [DayFocus]
    var today: CivilDay
    var calendar: Calendar
    var height: CGFloat

    private var peak: TimeInterval { days.map(\.focusedSeconds).max() ?? 0 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Capsule()
                        .fill(fill(day))
                        .frame(height: barHeight(day))
                        .frame(maxWidth: 18)
                        .frame(height: height, alignment: .bottom)
                    Text(calendar.veryShortWeekdaySymbols[day.day.weekday - 1])
                        .font(.caption2.weight(day.day == today ? .bold : .regular))
                        .foregroundStyle(day.day == today ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(Stats.durationText(day.focusedSeconds)) of focus")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(calendar.weekdaySymbols[day.day.weekday - 1]): \(Stats.durationText(day.focusedSeconds)) of focus")
            }
        }
    }

    /// Whole points, and never shorter than a dot, so an empty day still marks its place.
    private func barHeight(_ day: DayFocus) -> CGFloat {
        guard peak > 0 else { return 6 }
        return max(6, (height * day.focusedSeconds / peak).rounded())
    }

    private func fill(_ day: DayFocus) -> AnyShapeStyle {
        if day.focusedSeconds == 0 { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(PopoverStyle.accent.opacity(day.day == today ? 1 : 0.45))
    }
}
