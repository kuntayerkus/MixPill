import SwiftUI
import AppKit

/// Native NSVisualEffectView backdrop with behind-window blending, so the
/// popover subtly reflects the desktop wallpaper exactly like Control Center.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material = .popover
    public var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    public var state: NSVisualEffectView.State = .active

    public init(
        material: NSVisualEffectView.Material = .popover,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

/// HIG group title: subtle uppercase caption, System Settings style.
public struct SettingsSectionHeader: View {
    private let title: LocalizedStringKey

    /// Takes a `LocalizedStringKey`, not a `String`.
    ///
    /// `Text(someString)` is the *non-localizing* initializer, so every
    /// section title in the app was unreachable for translation, and any
    /// markup in one was printed literally rather than resolved.
    public init(_ title: LocalizedStringKey) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: Constants.UI.headerFontSize, weight: .bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}
