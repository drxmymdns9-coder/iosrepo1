#if canImport(UIKit)
import AnililiCore
import SwiftUI

// The Android app's settings vocabulary (`MidnightSettings.kt`, `MidnightSelectors.kt`): every row
// is a title, one line of description and the current value; the long explanation lives in the
// picker the row opens.

/// The row a search asked for, marked on the page it opened (Android's `MidnightSettingSpotlight`).
private struct SettingsSpotlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsSpotlight: String? {
        get { self[SettingsSpotlightKey.self] }
        set { self[SettingsSpotlightKey.self] = newValue }
    }
}

/// The panel every settings row sits in: a faint card with a 12 pt corner, the title, the
/// description under it, and whatever the row shows on the right. Its id is its title, which is
/// how a search result scrolls to it.
struct SettingsRowShell<Trailing: View>: View {
    @Environment(\.palette) private var palette
    @Environment(\.settingsSpotlight) private var spotlight
    let title: String
    var detail: String?
    var dimmed = false
    var danger = false
    var leading: AnyView?
    @ViewBuilder var trailing: Trailing

    private var ink: Color {
        if dimmed { return palette.disabledContent }
        return danger ? palette.error : palette.onSurface
    }

    var body: some View {
        HStack(spacing: 12) {
            if let leading {
                leading.foregroundStyle(ink).padding(.trailing, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.bodyMedium.weight(.semibold))
                    .foregroundStyle(ink)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppFont.labelSmall)
                        .foregroundStyle(dimmed ? palette.disabledContent : palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
        .background(palette.onSurface.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if spotlight == title { SpotlightMark() }
        }
        .contentShape(Rectangle())
        .id(title)
    }
}

/// The searched-for row's mark: the accent's wash, breathing, with a 2 pt bar down the leading edge.
private struct SpotlightMark: View {
    @Environment(\.palette) private var palette
    @State private var breath = 0.4

    var body: some View {
        ZStack(alignment: .leading) {
            palette.primary.opacity(0.10 * breath)
            palette.primary.opacity(breath).frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breath = 1 }
        }
    }
}

/// The current value at a row's end, in the accent, and the chevron after it.
struct SettingValue: View {
    @Environment(\.palette) private var palette
    var value: String?
    var enabled = true
    var chevron = true

    var body: some View {
        HStack(spacing: 4) {
            if let value {
                Text(value)
                    .font(AppFont.labelMedium.weight(.bold))
                    .foregroundStyle(enabled ? palette.primary : palette.text3)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.text3)
            }
        }
    }
}

/// "Connected" with a green dot, or the action that would connect (Android's
/// `MidnightConnectionStatus`).
struct ConnectionStatus: View {
    @Environment(\.palette) private var palette
    let text: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if connected { Circle().fill(Color.green).frame(width: 7, height: 7) }
            Text(text)
                .font(AppFont.labelMedium.weight(.bold))
                .foregroundStyle(connected ? palette.onSurface : palette.primary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text3)
        }
    }
}

/// A row whose value is a switch. Tapping anywhere on the row toggles it.
struct ToggleRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        SettingsRowShell(title: title, detail: detail, dimmed: disabled) {
            Toggle("", isOn: $isOn).labelsHidden().tint(palette.switchTint).disabled(disabled)
        }
        .onTapGesture { if !disabled { isOn.toggle() } }
        .accessibilityElement(children: .combine)
    }
}

/// A row that opens a picker of choices and shows the current one (Android's `MidnightSettingRow`
/// over a `MidnightChoicePicker`).
struct ChoiceRow<Value: Hashable>: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var disabled = false
    /// The small heading over the picker's title: the section the row is in.
    var kicker: String?
    /// The long explanation, which lives in the picker rather than under the row.
    var explanation: String?
    var optionDetail: ((Value) -> String?)?
    /// Choices that restyle the app (theme pickers) keep the picker open to compare them.
    var keepsOpen = false
    /// The row's value when it isn't simply the choice's label.
    var value: String?
    var leading: AnyView?
    /// Shown under the options, as Android's "Fine tune" stepper is.
    var fineTune: AnyView?
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            SettingsRowShell(title: title, detail: detail, dimmed: disabled, leading: leading) {
                SettingValue(value: value ?? label(selection), enabled: !disabled)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .sheet(isPresented: $open) {
            ChoicePickerSheet(kicker: kicker, title: title, explanation: explanation, options: options, label: label,
                              detail: optionDetail, selection: $selection, keepsOpen: keepsOpen, extra: fineTune)
                .settingsSheet(palette)
        }
    }
}

/// A row that does something when tapped.
struct ActionRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var detail: String?
    var value: String?
    var destructive = false
    var busy = false
    var disabled = false
    var chevron = true
    var leading: AnyView?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowShell(title: title, detail: detail, dimmed: disabled, danger: destructive, leading: leading) {
                if busy {
                    ProgressView().controlSize(.small).tint(palette.primary)
                } else {
                    SettingValue(value: value, enabled: !disabled, chevron: chevron)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
    }
}

/// A plain row that shows a fact and does nothing.
struct InfoRow: View {
    let title: String
    var detail: String?
    var value: String?

    var body: some View {
        SettingsRowShell(title: title, detail: detail) {
            SettingValue(value: value, chevron: false)
        }
    }
}

/// Android's `MidnightSectionLabel`: a short accent bar and the group's name.
struct SettingsSectionHeader: View {
    @Environment(\.palette) private var palette
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(palette.primary).frame(width: 2, height: 11)
            Text(title.uppercased())
                .font(AppFont.labelMedium.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(palette.onSurfaceVariant)
        }
        .padding(.leading, 14)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A search for "Theme presets" lands on the heading over them.
        .id(title)
    }
}

/// A line of feedback under the rows (Android's `MidnightInlineNotice`).
struct SettingsNotice: View {
    enum Tone { case info, success, warning, error }

    @Environment(\.palette) private var palette
    let text: String
    var tone: Tone = .info

    private var colour: Color {
        switch tone {
        case .info: return palette.primary
        case .success: return .green
        case .warning: return .orange
        case .error: return palette.error
        }
    }

    private var symbol: String {
        switch tone {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "exclamationmark.octagon"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(colour)
            Text(text)
                .font(AppFont.bodySmall)
                .foregroundStyle(palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(colour.opacity(0.25), lineWidth: 1))
        .padding(.vertical, 3)
    }
}

/// A note about something that works differently on iPhone, or arrives later.
struct ComingNote: View {
    let text: String

    var body: some View { SettingsNotice(text: text) }
}

// MARK: - Pickers

/// The heading of every picker and settings sheet: a kicker in the accent, the title, and an
/// optional line under it (Android's `MidnightMediaHeader`).
struct SettingsSheetHeader: View {
    @Environment(\.palette) private var palette
    var kicker: String?
    let title: String
    var metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let kicker {
                Text(kicker.uppercased())
                    .font(AppFont.labelSmall.weight(.bold))
                    .kerning(1.2)
                    .foregroundStyle(palette.primary)
            }
            Text(title)
                .font(AppFont.titleLarge.weight(.bold))
                .foregroundStyle(palette.onSurface)
            if let metadata {
                Text(metadata)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The page every settings sheet is drawn on: a header, a scrolling body and a footer of actions.
struct SettingsSheet<Content: View, Footer: View>: View {
    @Environment(\.palette) private var palette
    var kicker: String?
    let title: String
    var metadata: String?
    var explanation: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(kicker: kicker, title: title, metadata: metadata)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let explanation {
                        Text(explanation)
                            .font(AppFont.bodyMedium)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            HStack(spacing: 18) {
                footer
            }
            .font(AppFont.labelLarge.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(palette.background)
    }
}

extension View {
    /// What every settings sheet wears: the app's palette and accent, and Android's sheet sizes.
    func settingsSheet(_ palette: Palette) -> some View {
        environment(\.palette, palette)
            .tint(palette.primary)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(palette.background)
    }
}

/// One choice in a picker: a radio ring, the label, an optional line under it and a note on the
/// right (Android's `MidnightChoiceRow`).
struct ChoiceOptionRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    var trailing: String?
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? palette.onSurface : palette.onSurface.opacity(0.42), lineWidth: 1)
                    if selected { Circle().fill(palette.primary).padding(3) }
                }
                .frame(width: 15, height: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.bodyMedium.weight(.semibold)).foregroundStyle(enabled ? palette.onSurface : palette.disabledContent)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(AppFont.labelSmall).foregroundStyle(palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(AppFont.labelMedium.weight(.bold)).foregroundStyle(palette.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? palette.primary.opacity(0.16) : palette.onSurface.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A multi-select row: a checkbox, the label and an optional line (Android's `MidnightSelectionRow`).
struct SelectionOptionRow: View {
    @Environment(\.palette) private var palette
    let title: String
    var subtitle: String?
    var trailing: String?
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? palette.primary : palette.onSurface.opacity(0.42))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.bodyMedium.weight(.semibold)).foregroundStyle(enabled ? palette.onSurface : palette.disabledContent)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(AppFont.labelSmall).foregroundStyle(palette.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(AppFont.labelSmall.weight(.bold)).foregroundStyle(palette.primary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(palette.onSurface.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A value nudged rather than chosen: the number between two steps (Android's `MidnightStepperRow`).
struct StepperRow: View {
    @Environment(\.palette) private var palette
    let label: String
    let value: String
    let decrease: String
    let increase: String
    var canDecrease = true
    var canIncrease = true
    let onDecrease: () -> Void
    let onIncrease: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(AppFont.bodyMedium.weight(.semibold)).foregroundStyle(palette.onSurface)
            Spacer()
            step(decrease, enabled: canDecrease, action: onDecrease)
            Text(value)
                .font(AppFont.titleMedium.monospacedDigit().weight(.bold))
                .foregroundStyle(palette.primary)
                .frame(minWidth: 52)
            step(increase, enabled: canIncrease, action: onIncrease)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 53)
        .background(palette.onSurface.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 6)
    }

    private func step(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(AppFont.labelLarge.weight(.bold))
            .foregroundStyle(enabled ? palette.onSurface : palette.disabledContent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.onSurface.opacity(0.08), in: Capsule())
            .buttonStyle(.plain)
            .disabled(!enabled)
    }
}

/// The picker a choice row opens (Android's `MidnightChoicePicker`): the explanation, then every
/// option with its own line, the current one marked.
struct ChoicePickerSheet<Value: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    var kicker: String?
    let title: String
    var explanation: String?
    let options: [Value]
    let label: (Value) -> String
    var detail: ((Value) -> String?)?
    var trailing: ((Value) -> String?)?
    @Binding var selection: Value
    var keepsOpen = false
    var notice: String?
    var extra: AnyView?
    var onSelect: ((Value) -> Void)?

    var body: some View {
        SettingsSheet(kicker: kicker, title: title, explanation: explanation) {
            ForEach(options, id: \.self) { option in
                ChoiceOptionRow(title: label(option), subtitle: detail?(option), trailing: trailing?(option),
                                selected: option == selection) {
                    selection = option
                    onSelect?(option)
                    if !keepsOpen { dismiss() }
                }
            }
            if let extra { extra }
            if let notice { SettingsNotice(text: notice) }
        } footer: {
            Button("Close") { dismiss() }
        }
    }
}
#endif
