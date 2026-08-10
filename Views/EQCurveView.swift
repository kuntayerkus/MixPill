import SwiftUI
import Accelerate

/// The combined frequency response of the five bands, drawn from the same
/// biquad maths the engine runs.
///
/// Five numbers do not tell anyone what their audio will sound like. The
/// curve does, and it is the picture every equaliser in the world shows —
/// leaving it out is what made the EQ feel like a settings form rather than
/// an audio control.
///
/// The magnitude is evaluated from the transfer function of the peaking
/// biquads MixPill actually uses, so what is drawn is what is applied:
///
///     H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
struct EQCurveView: View {
    /// Band gains in dB, in `BiquadDesigner.bandFrequencies` order.
    var gains: [Float]
    /// The vertical extent of the plot, in dB.
    var range: Float = 12

    private static let bandFrequencies: [Float] = [100, 400, 1000, 4000, 10000]
    private static let minHz: Float = 20
    private static let maxHz: Float = 20000
    private static let sampleRate: Float = 48000
    private static let resolution = 160

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .frame(height: 78)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .animation(.smooth(duration: 0.25), value: gains)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2

        // 0 dB reference.
        var zeroLine = Path()
        zeroLine.move(to: CGPoint(x: 0, y: midY))
        zeroLine.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(zeroLine, with: .color(.primary.opacity(0.16)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

        // Band centres, so the sliders below map to somewhere on the curve.
        for frequency in Self.bandFrequencies {
            let x = position(of: frequency, width: size.width)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: 0))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tick, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
        }

        let points = curvePoints(width: size.width, height: size.height)
        guard points.count > 1 else { return }

        var curve = Path()
        curve.move(to: points[0])
        for point in points.dropFirst() {
            curve.addLine(to: point)
        }

        // Fill between the curve and the 0 dB line: the shape of the boost
        // or cut reads faster than the line alone.
        var fill = curve
        fill.addLine(to: CGPoint(x: points[points.count - 1].x, y: midY))
        fill.addLine(to: CGPoint(x: points[0].x, y: midY))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(
            Gradient(colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.05)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height)
        ))

        context.stroke(curve, with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }

    private func curvePoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        let coefficients = Self.coefficients(for: gains)
        guard !coefficients.isEmpty else {
            return [CGPoint(x: 0, y: height / 2), CGPoint(x: width, y: height / 2)]
        }

        return (0..<Self.resolution).map { index in
            let t = Float(index) / Float(Self.resolution - 1)
            let frequency = Self.minHz * pow(Self.maxHz / Self.minHz, t)
            let dB = Self.magnitudeDB(of: coefficients, at: frequency)
            let clamped = max(-range, min(range, dB))
            let y = height / 2 - CGFloat(clamped / range) * (height / 2 - 6)
            return CGPoint(x: CGFloat(t) * width, y: y)
        }
    }

    private func position(of frequency: Float, width: CGFloat) -> CGFloat {
        let t = log(frequency / Self.minHz) / log(Self.maxHz / Self.minHz)
        return CGFloat(t) * width
    }

    // MARK: - Biquad maths, mirroring the engine

    /// RBJ peaking coefficients, normalized — the same design the render
    /// thread uses, so the drawing cannot drift from the sound.
    private static func coefficients(for gains: [Float]) -> [[Float]] {
        var rows: [[Float]] = []
        for (index, frequency) in bandFrequencies.enumerated() {
            let gainDB = index < gains.count ? gains[index] : 0
            guard abs(gainDB) >= 0.01 else { continue }

            let amplitude = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * Float.pi * frequency / sampleRate
            let sinW0 = sin(w0)
            let cosW0 = cos(w0)
            let alpha = sinW0 * sinh(log(2.0) / 2.0 * 1.0 * w0 / sinW0)

            let b0 = 1 + alpha * amplitude
            let b1 = -2 * cosW0
            let b2 = 1 - alpha * amplitude
            let a0 = 1 + alpha / amplitude
            let a1 = -2 * cosW0
            let a2 = 1 - alpha / amplitude
            rows.append([b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0])
        }
        return rows
    }

    /// Cascaded magnitude response in dB at one frequency.
    private static func magnitudeDB(of sections: [[Float]], at frequency: Float) -> Float {
        let w = 2 * Float.pi * frequency / sampleRate
        var total: Float = 0

        for section in sections {
            let (b0, b1, b2, a1, a2) = (section[0], section[1], section[2], section[3], section[4])
            // Evaluate on the unit circle: z⁻¹ = cos(w) − j·sin(w).
            let cosW = cos(w), sinW = sin(w)
            let cos2W = cos(2 * w), sin2W = sin(2 * w)

            let numeratorReal = b0 + b1 * cosW + b2 * cos2W
            let numeratorImag = -(b1 * sinW + b2 * sin2W)
            let denominatorReal = 1 + a1 * cosW + a2 * cos2W
            let denominatorImag = -(a1 * sinW + a2 * sin2W)

            let numeratorMagnitude = (numeratorReal * numeratorReal + numeratorImag * numeratorImag).squareRoot()
            let denominatorMagnitude = (denominatorReal * denominatorReal + denominatorImag * denominatorImag).squareRoot()
            guard denominatorMagnitude > 1e-9 else { continue }

            total += 20 * log10(max(numeratorMagnitude / denominatorMagnitude, 1e-9))
        }
        return total
    }
}
