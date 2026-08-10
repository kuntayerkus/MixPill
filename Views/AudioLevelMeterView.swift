import SwiftUI

/// Logic Pro / macOS Sound-style VU meter ballistics: fast attack,
/// exponential decay, rendered at display refresh rate with TimelineView
/// and Canvas. Pauses automatically when the signal is silent.
///
/// The bar is drawn on a **dBFS** scale, not on raw amplitude. Plotting
/// amplitude directly is arithmetically correct and visually useless:
/// music mastered to −18 dBFS RMS is 0.126 linear, so it filled an eighth
/// of the width, speech filled less, and the yellow and red zones — sited
/// at 0.75 and 0.92 of the bar — were unreachable during ordinary
/// listening. Every meter in every mixer is logarithmic for this reason.
public struct AudioLevelMeterView: View {
    var level: Float // 0.0 to 1.0 (RMS)
    var peak: Float  // 0.0 to 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayLevel: Float = 0
    @State private var displayPeak: Float = 0
    @State private var lastStepDate = Date.now
    @State private var clipUntil: Date?

    // Ballistics tuning
    private let attackRate: Double = 40    // exponential approach speed while rising
    private let releaseTau: Double = 0.30  // RMS bar decay time constant (s)
    private let peakTau: Double = 0.90     // peak tick decay time constant (s)

    /// How long a clip stays lit after the peak that caused it. Long enough
    /// to catch out of the corner of an eye, short enough not to nag.
    private static let clipHoldSeconds: TimeInterval = 2.0

    public init(level: Float, peak: Float) {
        self.level = level
        self.peak = peak
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : nil, paused: isIdle)) { timeline in
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
        guard clipUntil == nil else { return false }
        return level <= 0.001 && displayLevel <= 0.001 && displayPeak <= 0.001
    }

    private func step(to date: Date) {
        if peak >= AudioScale.amplitude(fromDecibels: AudioScale.clipThresholdDB) {
            clipUntil = date.addingTimeInterval(Self.clipHoldSeconds)
        } else if let clipUntil, date >= clipUntil {
            self.clipUntil = nil
        }

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

        // Reference tick where programme material should be peaking.
        let referenceX = CGFloat(AudioScale.meterPosition(forDecibels: -12)) * size.width
        context.fill(
            Path(CGRect(x: referenceX, y: 0, width: 0.5, height: size.height)),
            with: .color(Color.primary.opacity(0.16))
        )

        let levelPosition = AudioScale.meterPosition(forAmplitude: displayLevel)
        guard levelPosition > 0.005 else {
            drawClipIndicator(in: context, size: size)
            return
        }

        // Gradient fill, revealed by the smoothed level width. The colour
        // stops sit at the dB marks they name: −12 dB is where the amber
        // starts, −3 dB is where it turns red.
        let levelWidth = max(size.height, CGFloat(levelPosition) * size.width)
        let fillRect = CGRect(x: 0, y: 0, width: min(levelWidth, size.width), height: size.height)

        var fillContext = context
        fillContext.clip(to: Path(roundedRect: fillRect, cornerRadius: radius))

        let amberStop = Double(AudioScale.meterPosition(forDecibels: -12))
        let redStop = Double(AudioScale.meterPosition(forDecibels: -3))
        let gradient = Gradient(stops: [
            .init(color: .green, location: 0.0),
            .init(color: .green, location: amberStop - 0.02),
            .init(color: .yellow, location: amberStop),
            .init(color: .red, location: redStop)
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
        let peakPosition = AudioScale.meterPosition(forAmplitude: displayPeak)
        if peakPosition > 0.02 {
            let peakX = min(CGFloat(peakPosition) * size.width, size.width - 1.5)
            let peakRect = CGRect(x: peakX, y: 0, width: 1.5, height: size.height)
            context.fill(Path(peakRect), with: .color(Color.primary.opacity(0.45)))
        }

        drawClipIndicator(in: context, size: size)
    }

    /// A held red cap at the far right — the one thing a meter has to tell
    /// you that a moving bar cannot, because the moment has already passed.
    private func drawClipIndicator(in context: GraphicsContext, size: CGSize) {
        guard clipUntil != nil else { return }
        let width: CGFloat = 3
        let capRect = CGRect(x: size.width - width, y: 0, width: width, height: size.height)
        context.fill(
            Path(roundedRect: capRect, cornerRadius: size.height / 2),
            with: .color(.red)
        )
    }
}
