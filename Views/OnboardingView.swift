import SwiftUI

/// First-launch welcome flow in three steps: what MixPill does, what it
/// does with your audio, and the one permission it needs. Completion is
/// remembered in `hasCompletedOnboarding`; dismissing the window in any
/// way marks the onboarding as done so it never reappears uninvited.
public struct OnboardingView: View {
    @Environment(CoreBridge.self) private var coreBridge
    @Environment(AppDiscoveryService.self) private var discoveryService
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var step = 0
    @State private var hasFinished = false

    var onComplete: () -> Void

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    private static let stepCount = 3

    /// Readiness is measured, not assumed: the core has either found
    /// applications and tapped them or it has not.
    private var isReady: Bool {
        coreBridge.captureProblem == nil && !discoveryService.availableApps.isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            progressIndicator
                .padding(.top, 44)

            Divider()
                .opacity(0.5)
                .padding(.top, 16)

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)

            Divider()
                .opacity(0.5)

            controls
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(width: 560, height: 680)
        .background(VisualEffectBackground(material: .underWindowBackground, blendingMode: .withinWindow))
        .animation(Constants.Motion.spring, value: step)

    }

    // MARK: - Chrome

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: index == step ? 28 : 8, height: 8)
            }
        }
        .animation(Constants.Motion.spring, value: step)
    }

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch step {
            case 0: welcomeStep
            case 1: privacyStep
            default: readyStep
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .id(step)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("Back") {
                    step -= 1
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if step == Self.stepCount - 1 {
                Button("Start Mixing") {
                    finish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") {
                    step += 1
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)

                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text("Welcome to MixPill")
                    .font(.system(size: 26, weight: .bold))

                Text("Individual volume control for every app on your Mac — right from the menu bar.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                featureRow(
                    icon: "slider.horizontal.3",
                    title: "Per-App Mixing",
                    subtitle: "Independent volume, mute and live level meters for every application."
                )
                featureRow(
                    icon: "slider.vertical.3",
                    title: "5-Band EQ & Noise Gate",
                    subtitle: "Shape each app's sound with ready-made profiles, or silence background hum."
                )
                featureRow(
                    icon: "person.wave.2",
                    title: "Smart Ducking",
                    subtitle: "Music and games automatically dip while someone speaks in your calls."
                )
                featureRow(
                    icon: "checkmark.seal",
                    title: "Nothing to Install",
                    subtitle: "No audio driver, no system extension, no restart. MixPill uses macOS's own audio engine."
                )
            }
        }
        .padding(.vertical, 12)
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(Constants.UI.cardOpacity), in: RoundedRectangle(cornerRadius: Constants.UI.cornerRadius))
    }

    // MARK: - Step 2: Privacy

    private var privacyStep: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 44))
                .foregroundStyle(.green)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                Text("100% On-Device & Private")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.green.opacity(0.14)))

            VStack(spacing: 10) {
                Text("What MixPill does with your audio")
                    .font(.system(size: 15, weight: .semibold))

                Text("To give an app its own volume, MixPill receives that app's sound before it reaches your speakers, applies your settings, and plays it back. It asks for no permissions to do this — no screen recording, no microphone. Nothing is written to disk and nothing leaves your Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                privacyRow(icon: "wifi.slash", text: "No audio ever leaves your Mac")
                privacyRow(icon: "person.crop.circle.badge.checkmark", text: "No accounts, no analytics, no telemetry")
                privacyRow(icon: "bolt.circle", text: "Audio is processed live and immediately discarded")
                privacyRow(icon: "shippingbox.fill", text: "Audio runs in a separate service that survives an interface crash")
            }
        }
        .padding(.vertical, 20)
    }

    private func privacyRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 18) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "waveform")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 44))
                .foregroundStyle(isReady ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .animation(Constants.Motion.spring, value: isReady)

            VStack(spacing: 8) {
                Text(isReady ? "You're Ready" : "Listening for Audio")
                    .font(.system(size: 20, weight: .bold))

                Text(isReady
                     ? "MixPill is already mixing. Open it from the menu bar whenever you want to change something."
                     : "MixPill picks up an app as soon as it plays something. Start some audio and it will appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let problem = coreBridge.captureProblem {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Constants.UI.cornerRadius))
            } else {
                detectedApps
            }
        }
        .padding(.vertical, 20)
    }

    /// A live count is worth more than any reassurance we could write.
    private var detectedApps: some View {
        VStack(spacing: 8) {
            Text(discoveryService.availableApps.isEmpty
                 ? "No apps playing yet"
                 : "^[\(discoveryService.availableApps.count) app](inflect: true) ready to mix")
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.numericText())
                .animation(Constants.Motion.spring, value: discoveryService.availableApps.count)

            if !discoveryService.availableApps.isEmpty {
                Text(discoveryService.availableApps.prefix(4).map(\.name).joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(Constants.UI.cardOpacity), in: RoundedRectangle(cornerRadius: Constants.UI.cornerRadius))
    }

    // MARK: - Actions

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        hasCompletedOnboarding = true
        onComplete()
    }
}
