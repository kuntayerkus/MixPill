import SwiftUI

/// Logic Pro / macOS Sound-style VU meter ballistics: fast attack,
/// exponential decay, rendered at display refresh rate with TimelineView
/// and Canvas. Pauses automatically when the signal is silent.
public struct AudioLevelMeterView: View {
    var level: Float // 0.0 to 1.0 (RMS)
    var peak: Float  // 0.0 to 1.0

    @State private var displayLevel: Float = 0
    @State private var displayPeak: Float = 0
    @State private var lastStepDate = Date.now

    // Ballistics tuning
    private let attackRate: Double = 40    // exponential approach speed while rising
    private let releaseTau: Double = 0.30  // RMS bar decay time constant (s)
    private let peakTau: Double = 0.90     // peak tick decay time constant (s)

    public init(level: Float, peak: Float) {
        self.level = level
        self.peak = peak
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isIdle)) { timeline in
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .onChange(of: timeline.date) { _, newDate in
                step(to: newDate)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
        .onAppear {
            lastStepDate = .now
        }
    }

    private var isIdle: Bool {
        level <= 0.001 && displayLevel <= 0.001 && displayPeak <= 0.001
    }

    private func step(to date: Date) {
        let dt = date.timeIntervalSince(lastStepDate)
        lastStepDate = date
        guard dt > 0, dt < 0.5 else {
            // Schedule was paused or the system hiccuped: snap instead of animating.
            displayLevel = level
            displayPeak = max(displayPeak, peak)
            return
        }

        if level > displayLevel {
            // Fast attack: exponentially approach the incoming level.
            let blend = min(1.0, dt * attackRate)
            displayLevel += (level - displayLevel) * Float(blend)
        } else {
            // Exponential decay, never dropping below the live input.
            displayLevel = max(level, displayLevel * Float(exp(-dt / releaseTau)))
        }

        if peak > displayPeak {
            displayPeak = peak
        } else {
            displayPeak = max(peak, displayPeak * Float(exp(-dt / peakTau)))
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let radius = size.height / 2
        let trackRect = CGRect(origin: .zero, size: size)
        let track = Path(roundedRect: trackRect, cornerRadius: radius)

        // Background track
        context.fill(track, with: .color(Color.primary.opacity(0.08)))

        guard displayLevel > 0.004 else { return }

        // Gradient fill, revealed by the smoothed level width. Colors sit at
        // fixed absolute positions like the system output meter.
        let levelWidth = max(size.height, CGFloat(displayLevel) * size.width)
        let fillRect = CGRect(x: 0, y: 0, width: min(levelWidth, size.width), height: size.height)

        var fillContext = context
        fillContext.clip(to: Path(roundedRect: fillRect, cornerRadius: radius))

        let gradient = Gradient(stops: [
            .init(color: .green, location: 0.0),
            .init(color: .green, location: 0.55),
            .init(color: .yellow, location: 0.75),
            .init(color: .red, location: 0.92)
        ])
        fillContext.fill(
            track,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: 0)
            )
        )

        // Peak tick
        if displayPeak > 0.02 {
            let peakX = min(CGFloat(displayPeak) * size.width, size.width - 1.5)
            let peakRect = CGRect(x: peakX, y: 0, width: 1.5, height: size.height)
            context.fill(Path(peakRect), with: .color(Color.primary.opacity(0.45)))
        }
    }
}
