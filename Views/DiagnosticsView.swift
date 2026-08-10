import SwiftUI
import Darwin

/// Pro-level system health dashboard: live CoreAudio status, resampler and
/// stream census, CPU load, and one-click engine recovery. Refreshes once
/// per second while visible; every metric is answered by the MixPillCore
/// service over XPC.
public struct DiagnosticsView: View {
    @Environment(CoreBridge.self) private var coreBridge
    @State private var snapshot = DiagnosticsSnapshot()
    @State private var poll: Timer?

    private let cpuSampler = SystemCPUSampler()

    public init() {}

    public var body: some View {
        Form {
            Section {
                statusRow(
                    "Engine Health",
                    healthy: snapshot.engineHealthy,
                    value: snapshot.engineHealthy ? "Healthy" : "Degraded"
                )
                metricRow("Hardware I/O Block", value: "\(snapshot.ioBufferFrames) frames")
                metricRow("I/O Latency", value: String(format: "%.1f ms", snapshot.latencyMS))
                metricRow("Channel Ring Depth", value: "\(snapshot.ringCapacityFrames) frames")
                metricRow(
                    "Hardware Sample Rate",
                    value: snapshot.hardwareSampleRate.map { String(format: "%.0f Hz", $0) } ?? "—"
                )
            } header: {
                SettingsSectionHeader("CoreAudio")
            } footer: {
                Text("Mixing runs in a single real-time render pass; latency is the hardware I/O block plus the tiny channel ring, nothing more. With nothing playing, MixPill stops its output unit so the audio device can sleep.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section {
                metricRow("Active App Taps", value: "\(snapshot.activeTaps)")
                metricRow(
                    "Output Engines",
                    value: snapshot.activeEngines == 0
                        ? "Idle (hardware released)"
                        : "\(snapshot.activeEngines) running"
                )
                metricRow("System CPU", value: snapshot.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
            } header: {
                SettingsSectionHeader("Capture & System")
            }

            Section {
                metricRow("Last Recovery", value: snapshot.lastRecoveryReason)
                if let date = snapshot.lastRecoveryDate {
                    metricRow("Recovered At", value: date.formatted(date: .abbreviated, time: .standard))
                }

                Button(role: .destructive) {
                    coreBridge.performManualRecovery()
                    refresh()
                } label: {
                    Label("Reset Audio Engine", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Rebuilds every output engine and re-applies routing without restarting the app")
            } header: {
                SettingsSectionHeader("Recovery")
            } footer: {
                Text("Rebuilds the entire output graph and re-arms captures. Takes under a second; no app restart needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // An explicitly owned timer, started and stopped with the view.
        //
        // `Timer.publish(…).autoconnect()` inside `onReceive` builds a new
        // publisher on every body evaluation, and — because the Settings
        // window is retained rather than released on close, and a macOS
        // TabView keeps unselected tabs alive — it kept asking the audio
        // service for diagnostics once a second long after anyone was
        // looking at them.
        .onAppear {
            refresh()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
            timer.tolerance = 0.2
            poll = timer
        }
        .onDisappear {
            poll?.invalidate()
            poll = nil
        }
    }

    // MARK: - Rows

    private func statusRow(_ label: String, healthy: Bool, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(healthy ? Color.green : Color.yellow)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Refresh

    private func refresh() {
        snapshot.cpuPercent = cpuSampler.sample()
        coreBridge.requestDiagnostics { result in
            guard let result else { return }
            snapshot.engineHealthy = result.engineHealthy
            snapshot.ioBufferFrames = result.ioBufferFrames
            snapshot.latencyMS = result.ioLatencyMS
            snapshot.ringCapacityFrames = result.ringCapacityFrames
            snapshot.activeTaps = result.activeTaps
            snapshot.activeEngines = result.activeEngines
            snapshot.hardwareSampleRate = result.hardwareSampleRate
            snapshot.lastRecoveryReason = result.lastRecoveryReason
            snapshot.lastRecoveryDate = result.lastRecoveryDate
        }
    }
}

private struct DiagnosticsSnapshot {
    var engineHealthy = true
    var ioBufferFrames = 0
    var latencyMS: Double = 0
    var ringCapacityFrames = 0
    var activeTaps = 0
    var activeEngines = 0
    var hardwareSampleRate: Double?
    var cpuPercent: Double?
    var lastRecoveryReason = "None"
    var lastRecoveryDate: Date?
}

/// Whole-machine CPU usage, computed from the delta of Mach host load info
/// between two samples.
private final class SystemCPUSampler {
    private var previous: host_cpu_load_info_data_t?

    func sample() -> Double? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var info = host_cpu_load_info_data_t()
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { rawPointer in
                host_statistics(host, HOST_CPU_LOAD_INFO, rawPointer, &size)
            }
        }
        // `mach_host_self()` hands back a send right on every call. Without
        // this the diagnostics panel leaked one per second for as long as
        // it was open — `RealtimeThread` gets the same detail right for
        // `mach_thread_self()`, this one was simply missed.
        mach_port_deallocate(mach_task_self_, host)

        guard result == KERN_SUCCESS else { return nil }

        defer { previous = info }
        guard let previous else { return nil }

        let user = Double(info.cpu_ticks.0 - previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 - previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 - previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 - previous.cpu_ticks.3)

        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total * 100.0
    }
}
