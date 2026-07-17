import Foundation

/// Single source of truth for how dates and times are displayed anywhere in
/// the app: the info panel, selection summaries, filter day lists, and group
/// headers.
///
/// Formatting follows the Mac's settings (System Settings > General >
/// Language & Region / Date & Time), including the user's custom "Date
/// format" picker. That picker stores a per-style override
/// (`AppleICUDateFormatStrings`) which only style-based formatters honor —
/// `setLocalizedDateFormatFromTemplate` silently ignores it and falls back
/// to the region default — so the formatters below must be configured via
/// `dateStyle`/`timeStyle`, never via templates or explicit patterns. If an
/// in-app date format setting ever lands, only this file needs to change:
/// no call site should ever build its own display DateFormatter.
enum AppDateFormat {
    /// e.g. "2026.07.11"
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// e.g. "2026.07.11, 2:32 PM" (12/24-hour clock per system setting)
    static func dayAndTime(_ date: Date) -> String {
        dayAndTimeFormatter.string(from: date)
    }

    /// e.g. "2023.03.28 – 2026.07.11". Composed from two `day` strings so
    /// both ends always render the full, identical pattern.
    static func dayRange(from start: Date, to end: Date) -> String {
        "\(day(start)) – \(day(end))"
    }

    /// Built once per launch; a mid-session change to the Mac's region
    /// settings needs a relaunch. Deliberately NOT the POSIX locale used for
    /// EXIF parsing: display formatting should follow the user's system,
    /// fixed-format parsing must not. The short styles are what the System
    /// Settings pickers customize.
    private static func makeFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }

    private static let dayFormatter = makeFormatter(dateStyle: .short, timeStyle: .none)
    private static let dayAndTimeFormatter = makeFormatter(dateStyle: .short, timeStyle: .short)
}
