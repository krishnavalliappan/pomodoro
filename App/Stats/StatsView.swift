import Charts
import PomodoroCore
import SwiftUI

/// The planner's Stats tab: a week of focus as bars, totals against the week before, the
/// week's top tasks and the streak.
struct StatsView: View {
    static let minSize = CGSize(width: 640, height: 420)
    static let taskColumnWidth: CGFloat = 280

    @State private var store: StatsStore

    init(model: AppModel, store: StatsStore? = nil) {
        _store = State(initialValue: store ?? StatsStore(model: model))
    }

    private var report: WeekReport { store.report }
    private var model: AppModel { store.model }

    /// Restarts the observation for another week, weekday setting or day.
    private struct ObservationKey: Hashable {
        var week: StatsWeek
        var firstWeekday: Int?
        var today: CivilDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            tiles
            HStack(alignment: .top, spacing: 16) {
                chartCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TopTasksCard(tasks: report.topTasks, isCurrentWeek: store.isCurrentWeek)
                    .frame(width: Self.taskColumnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .opacity(store.isStale ? 0.5 : 1)
        }
        .padding(20)
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: ObservationKey(week: store.week, firstWeekday: model.settings.firstWeekday, today: model.today.day)) {
            await store.observe()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button(action: store.showPreviousWeek) {
                    Image(systemName: "chevron.left").frame(width: 18)
                }
                .help("Previous week")
                .accessibilityLabel("Previous week")
                Button(action: store.showNextWeek) {
                    Image(systemName: "chevron.right").frame(width: 18)
                }
                .disabled(store.isCurrentWeek)
                .help("Next week")
                .accessibilityLabel("Next week")
            }
            .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.title(for: store.week, calendar: model.database.calendar))
                    .font(.title3.weight(.semibold))
                Text(relativeWeek)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.isCurrentWeek {
                Button("This Week", action: store.showCurrentWeek)
            }
        }
    }

    private var relativeWeek: String {
        let weeks = store.week.start.days(to: store.stats.week(containing: store.today).start) / 7
        switch weeks {
        case 0: return "This week"
        case 1: return "Last week"
        default: return "\(weeks) weeks ago"
        }
    }

    /// "Oct 12 – 18, 2026", in the user's locale.
    static func title(for week: StatsWeek, calendar: Calendar) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: week.start.start(in: calendar), to: week.last.start(in: calendar))
    }

    // MARK: - Tiles

    private var tiles: some View {
        let current = store.isCurrentWeek
        return HStack(spacing: 12) {
            StatTile(
                label: current ? "This week" : "That week",
                value: Stats.durationText(report.totalSeconds),
                detail: comparison
            )
            StatTile(
                label: current ? "Last week" : "Week before",
                value: Stats.durationText(report.previousWeekSeconds),
                detail: report.completedPomodoros == 1 ? "1 pomodoro this week" : "\(report.completedPomodoros) pomodoros this week"
            )
            StatTile(
                label: "Current streak",
                value: report.streak.current > 0 ? "🔥 \(Self.days(report.streak.current))" : "0 days",
                detail: report.streak.current > 0 ? "Keep it going today" : "Finish a pomodoro to start one"
            )
            StatTile(
                label: "Best streak",
                value: Self.days(report.streak.best),
                detail: report.streak.best > 0 && report.streak.best == report.streak.current ? "That's now" : " "
            )
        }
    }

    private var comparison: String {
        let delta = report.totalSeconds - report.previousWeekSeconds
        if report.previousWeekSeconds == 0 && report.totalSeconds == 0 { return "No focus yet" }
        if abs(delta) < 60 { return "Same as the week before" }
        return "\(delta > 0 ? "▲" : "▼") \(Stats.durationText(abs(delta))) vs the week before"
    }

    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Focus per day")
                .font(.headline)
            WeekChart(days: report.days, today: report.today, calendar: model.database.calendar)
                .overlay {
                    if report.isEmpty {
                        VStack(spacing: 4) {
                            Text("No focus logged this week")
                                .font(.callout.weight(.medium))
                            Text("Finished and stopped pomodoros show up here.")
                                .font(.callout)
                        }
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
                    }
                }
        }
        .statsCard()
    }
}

/// Focus minutes per day, today in full colour.
struct WeekChart: View {
    var days: [DayFocus]
    var today: CivilDay
    var calendar: Calendar

    @Environment(\.colorScheme) private var colorScheme

    /// Other days' bars: a faded tint, less faded on dark, where 40% sinks into the background.
    private var pastTint: Color {
        PhaseStyle.focusTint.opacity(colorScheme == .dark ? 0.62 : 0.4)
    }

    private var maxMinutes: Double {
        days.map { $0.focusedSeconds / 60 }.max() ?? 0
    }

    /// Room above the tallest bar for its label; at least an hour so an empty week has a scale.
    private var yDomain: ClosedRange<Double> {
        0...max(60, maxMinutes * 1.18)
    }

    /// Gridlines on round durations, never "1h 40m".
    private var yTicks: [Double] {
        let top = yDomain.upperBound
        let step: Double = top <= 60 ? 15 : top <= 150 ? 30 : top <= 480 ? 60 : 120
        return Array(stride(from: 0, through: top, by: step))
    }

    var body: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", label(day.day)),
                y: .value("Minutes", day.focusedSeconds / 60),
                width: .ratio(0.62)
            )
            .foregroundStyle(day.day == today ? PhaseStyle.focusTint : pastTint)
            .cornerRadius(4)
            .annotation(position: .top, spacing: 4) {
                if day.focusedSeconds >= 60 {
                    Text(Stats.durationText(day.focusedSeconds))
                        .font(.caption2.weight(day.day == today ? .semibold : .regular))
                        .foregroundStyle(day.day == today ? .primary : .secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityLabel(Text(label(day.day)))
            .accessibilityValue(Text(Stats.durationText(day.focusedSeconds)))
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(Stats.durationText(minutes * 60))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let text = value.as(String.self) {
                        Text(text)
                            .fontWeight(text == label(today) ? .bold : .regular)
                            .foregroundStyle(text == label(today) ? AnyShapeStyle(PhaseStyle.focusTint) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
    }

    /// "Mon 12": unique within a week, which a categorical axis needs.
    private func label(_ day: CivilDay) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return "\(symbols[(day.weekday - 1) % symbols.count]) \(day.day)"
    }
}

struct TopTasksCard: View {
    static let rowLimit = 5

    var tasks: [TaskStat]
    var isCurrentWeek: Bool

    private var maxSeconds: TimeInterval {
        tasks.map(\.week.focusedSeconds).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Top tasks")
                    .font(.headline)
                Spacer()
                // The bars are this week's; the dots are the task's whole life against its estimate.
                Text("All-time done / estimate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if tasks.isEmpty {
                Text(isCurrentWeek ? "Pick a task before you start a focus, and its time shows up here." : "No focus on tasks this week.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tasks.prefix(Self.rowLimit)) { task in
                        row(task)
                    }
                }
            }
        }
        .statsCard()
    }

    private func row(_ task: TaskStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.title)
                Spacer(minLength: 4)
                EstimateDots(estimate: task.estimatePomodoros, actual: task.allTime.completedPomodoros)
            }
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(PhaseStyle.focusTint.opacity(0.55))
                        .frame(width: max(4, proxy.size.width * fraction(task)))
                }
                .frame(height: 4)
                Text(Stats.durationText(task.week.focusedSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                    .help(isCurrentWeek ? "Focus this week" : "Focus in the selected week")
            }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(task))
    }

    private func accessibilityText(_ task: TaskStat) -> String {
        let week = "\(Stats.durationText(task.week.focusedSeconds)) \(isCurrentWeek ? "this week" : "in the selected week")"
        let done = task.allTime.completedPomodoros
        let lifetime = task.estimatePomodoros.map { "\(done) of \($0) pomodoros done all-time" } ?? "\(done) pomodoros done all-time"
        return "\(task.title)\(task.isDone ? ", done" : ""), \(week), \(lifetime)"
    }

    private func fraction(_ task: TaskStat) -> CGFloat {
        maxSeconds > 0 ? CGFloat(task.week.focusedSeconds / maxSeconds) : 0
    }
}

struct StatTile: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCard()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    fileprivate func statsCard() -> some View {
        padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
