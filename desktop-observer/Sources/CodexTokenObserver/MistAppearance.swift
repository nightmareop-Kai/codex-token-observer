import SwiftUI

extension ObserverAppearance {
    var digitWidth: CGFloat { self == .mist ? 0.62 : 0.52 }
    var groupSpacing: CGFloat { self == .mist ? 0.22 : 0.28 }
    func digitFont(size: CGFloat) -> Font {
        self == .mist ? .system(size: size, weight: .medium) : .custom("Avenir Next Condensed", size: size).weight(.medium)
    }
}

struct AppearanceOptions: View {
    let appearance: ObserverAppearance
    let onSelect: (ObserverAppearance) -> Void

    var body: some View {
        ForEach(ObserverAppearance.allCases) { option in
            Button { onSelect(option) } label: {
                if appearance == option {
                    Label(option.title, systemImage: "checkmark")
                } else {
                    Text(option.title)
                }
            }
        }
    }
}

struct AppearanceMenu: View {
    let appearance: ObserverAppearance
    let tint: Color
    let onSelect: (ObserverAppearance) -> Void

    var body: some View {
        Menu {
            AppearanceOptions(appearance: appearance, onSelect: onSelect)
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch appearance · \(appearance.title)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(appearance.title)
    }
}

private struct MistPalette {
    let dark: Bool
    var ink: Color { dark ? Color(red: 0.94, green: 0.95, blue: 0.97) : Color(red: 0.12, green: 0.15, blue: 0.18) }
    var secondary: Color { dark ? Color(red: 0.68, green: 0.72, blue: 0.78) : Color(red: 0.38, green: 0.41, blue: 0.46) }
    var zero: Color { dark ? Color(red: 0.43, green: 0.47, blue: 0.53) : Color(red: 0.61, green: 0.65, blue: 0.70) }
    var accent: Color { dark ? Color(red: 0.43, green: 0.70, blue: 1) : Color(red: 0, green: 0.37, blue: 0.79) }
    var surface: Color { dark ? Color(red: 0.15, green: 0.18, blue: 0.22) : Color(red: 0.96, green: 0.97, blue: 0.98) }
    var rule: Color { ink.opacity(dark ? 0.13 : 0.10) }

    // A deeper light-mode ramp keeps the small percentage readable on material.
    func quotaTint(_ percent: Double?) -> Color {
        guard let percent else { return secondary }
        let p = min(100, max(0, percent))
        let green = dark ? (0.36, 0.83, 0.59) : (0.10, 0.46, 0.29)
        let yellow = dark ? (0.96, 0.79, 0.34) : (0.54, 0.38, 0.04)
        let red = dark ? (1.0, 0.43, 0.42) : (0.76, 0.18, 0.17)
        let a = p < 60 ? green : yellow
        let b = p < 60 ? yellow : red
        let t = p < 60 ? p / 60 : (p - 60) / 40
        return Color(red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t, blue: a.2 + (b.2 - a.2) * t)
    }
}

struct MistObserverContent: View {
    let today: Double
    let total: Double
    let projects: [ProjectSnapshot]
    let isConnected: Bool
    let showPanelBackground: Bool
    let quota: QuotaSnapshot?
    let showAllProjects: Bool
    let onToggleProjects: () -> Void
    let onSelectAppearance: (ObserverAppearance) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var projectsHovered = false

    private var palette: MistPalette { MistPalette(dark: colorScheme == .dark) }
    private var quotaTint: Color { palette.quotaTint(quota?.percent) }
    private var warningTint: Color? { quota?.isOverLimit == true ? quotaTint : nil }
    private var visibleProjects: [ProjectSnapshot] { showAllProjects ? projects : Array(projects.prefix(3)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
                    .background(palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                Text("Token Observer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 4)
                Circle().fill(isConnected ? palette.accent : Color.orange)
                    .frame(width: 4, height: 4)
                Text(isConnected ? "Live" : "Sync")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.secondary)
                AppearanceMenu(appearance: .mist, tint: palette.secondary, onSelect: onSelectAppearance)
            }
            .padding(.bottom, 12)

            weeklyUsage.padding(.bottom, 10)

            VStack(spacing: 4) {
                counter(label: "Today", value: today, primary: true)
                counter(label: "Total", value: total, primary: false)
            }
            .padding(.bottom, 12)

            Rectangle().fill(palette.rule).frame(height: 0.5)
            Button(action: onToggleProjects) {
                HStack(spacing: 4) {
                    Text("Projects · Today").font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text(showAllProjects ? "Collapse" : "All \(projects.count)").font(.system(size: 9))
                    Image(systemName: showAllProjects ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(projectsHovered ? palette.accent : palette.secondary)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { projectsHovered = $0 }
            .help(showAllProjects ? "Ranked by today's usage. Click to show only the top three." : "Show all projects, ranked by today's usage.")
            .accessibilityLabel(showAllProjects ? "Collapse project list" : "Show all \(projects.count) projects")

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(visibleProjects.enumerated()), id: \.element.id) { index, project in
                        projectRow(rank: index + 1, project: project, showToday: index < 3)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(showAllProjects ? .automatic : .hidden)
            .scrollDisabled(!showAllProjects)
            .frame(height: showAllProjects ? ObserverStyle.expandedProjectHeight : ObserverStyle.compactProjectHeight)
            .overlay {
                if projects.isEmpty {
                    Text(isConnected ? "Waiting for project activity" : "Reading local activity…")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: ObserverStyle.bodyWidth)
        .background {
            if showPanelBackground {
                let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                ZStack {
                    if reduceTransparency { shape.fill(palette.surface) }
                    else {
                        shape.fill(.regularMaterial)
                        shape.fill(palette.surface.opacity(colorScheme == .dark ? 0.42 : 0.30))
                    }
                    shape.strokeBorder(palette.ink.opacity(colorScheme == .dark ? 0.13 : 0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 10, y: 4)
            }
        }
        .padding(ObserverStyle.outerPadding)
    }

    private var weeklyUsage: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text("Weekly usage").font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                if quota?.stale == true {
                    Text("Stale").font(.system(size: 8)).foregroundStyle(palette.secondary)
                }
                Spacer()
                Text(quota?.percent.map { (quota?.estimated == true ? "≈ " : "") + String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(quotaTint)
            }
            .frame(height: 14)
            GeometryReader { geometry in
                Capsule().fill(palette.rule)
                Capsule().fill(quotaTint)
                    .frame(width: geometry.size.width * min(1, max(0, (quota?.percent ?? 0) / 100)))
            }
            .frame(height: 3)
        }
        .help(quota?.detail ?? "Reading weekly account usage…")
        .accessibilityElement(children: .combine)
    }

    private func counter(label: String, value: Double, primary: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.secondary)
                .frame(width: 32, alignment: .leading)
            RollingNumber(value: value, size: primary ? 25 : 19,
                          tint: warningTint ?? (primary ? palette.accent : palette.ink),
                          appearance: .mist, zeroTint: palette.zero)
        }
    }

    private func projectRow(rank: Int, project: ProjectSnapshot, showToday: Bool) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", rank)).font(.system(size: 8, weight: .medium)).monospacedDigit()
                .foregroundStyle(palette.secondary)
                .frame(width: 12, alignment: .leading)
            Text(project.displayName)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2).truncationMode(.tail).lineSpacing(1)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(project.path.isEmpty ? "Project directory not identified." : "\(project.name)\n\(project.path)")
            VStack(spacing: 4) {
                if showToday { projectMetric(label: "Today", value: project.today, primary: true) }
                if showAllProjects { projectMetric(label: "Total", value: project.total, primary: false) }
            }
            .frame(width: showAllProjects ? 132 : 116)
        }
        .frame(height: showToday && showAllProjects ? 34 : 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today rank \(rank), \(project.displayName)"
            + (showToday ? ", today \(Int64(project.today)) tokens" : "")
            + (showAllProjects ? ", total \(Int64(project.total)) tokens" : ""))
    }

    private func projectMetric(label: String, value: Double, primary: Bool) -> some View {
        HStack(spacing: 4) {
            if showAllProjects {
                Text(label).font(.system(size: 7))
                    .foregroundStyle(palette.secondary)
                    .frame(width: 24, alignment: .leading)
            }
            RollingNumber(value: value, size: 11, tint: warningTint ?? (primary ? palette.accent : palette.ink),
                          appearance: .mist, zeroTint: palette.zero)
        }
    }
}
