import Darwin
import Foundation
import QuartzCore
import UIKit

/// Frame pacing as seen by the app's main thread.
///
/// A display link fires once per screen refresh while the main thread is
/// free. When the main thread is busy for longer than a frame, callbacks are
/// skipped, so the gaps between callbacks show how many frames were missed.
/// This does not see work done in other processes (WKWebView's renderer).
@MainActor
final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var timestamps: [CFTimeInterval] = []
    private var frameDuration: CFTimeInterval = 1.0 / 60

    func start() {
        timestamps.removeAll()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // The screen's full rate: 120 Hz on a ProMotion iPhone when the app
        // opts in (run.py --promotion), 60 Hz otherwise.
        let fastest = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fastest), maximum: fastest, preferred: fastest)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        timestamps.append(link.timestamp)
        frameDuration = link.targetTimestamp - link.timestamp
    }

    func stop() -> FrameStats {
        link?.invalidate()
        link = nil
        let intervals = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }
        return FrameStats(intervals: intervals, frameDuration: frameDuration)
    }
}

struct FrameStats: Codable {
    var frames: Int
    var seconds: Double
    var frameMs: Double
    /// Refreshes that passed without a callback.
    var droppedFrames: Int
    /// Milliseconds of delay beyond one frame, per second of run time.
    var hitchMsPerSecond: Double
    var worstFrameMs: Double
    var p99FrameMs: Double

    init(intervals: [Double], frameDuration: Double) {
        let total = intervals.reduce(0, +)
        frames = intervals.count
        seconds = total
        frameMs = frameDuration * 1000
        droppedFrames = intervals.reduce(0) { $0 + max(Int(($1 / frameDuration).rounded()) - 1, 0) }
        let hitch = intervals.filter { $0 > frameDuration * 1.5 }.reduce(0) { $0 + ($1 - frameDuration) }
        hitchMsPerSecond = total > 0 ? hitch * 1000 / total : 0
        let sorted = intervals.sorted()
        worstFrameMs = (sorted.last ?? 0) * 1000
        p99FrameMs = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))] * 1000
    }
}

enum Clock {
    private static func seconds(_ id: clockid_t) -> Double {
        var time = timespec()
        clock_gettime(id, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    /// CPU time used by the calling thread.
    static func threadCPU() -> Double { seconds(CLOCK_THREAD_CPUTIME_ID) }
    /// CPU time used by all threads of this process.
    static func processCPU() -> Double { seconds(CLOCK_PROCESS_CPUTIME_ID) }
}

enum Memory {
    /// The process's physical footprint in megabytes: current and lifetime peak.
    static func footprintMB() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let megabyte = 1024.0 * 1024.0
        return (Double(info.phys_footprint) / megabyte, Double(info.ledger_phys_footprint_peak) / megabyte)
    }
}

struct BenchResult: Codable {
    var renderer: String
    var scenario: String
    var characters: Int
    var charactersPerSecond: Int
    var historyMessages: Int
    var frames: FrameStats
    /// Frame pacing measured inside the web page (WKWebView only).
    var pageFrames: FrameStats?
    var mainThreadCPUSeconds: Double
    var processCPUSeconds: Double
    var memoryBeforeMB: Double
    var memoryAfterMB: Double
    /// After asking malloc to return free pages, as the system does under
    /// memory pressure: memory actually in use rather than cached.
    var memoryAfterReliefMB: Double
    var memoryPeakMB: Double
    /// TranscriptKit only: layouts installed, tile redraws on the main
    /// thread, and tails drawn on the layout queue.
    var installs: Int?
    var tileDraws: Int?
    var tailFrames: Int?
    /// The conditions the run happened in: the screen's top rate, Low Power
    /// Mode and the thermal state (0 nominal, 1 fair, 2 serious, 3 critical).
    var screenMaxFPS: Int?
    var lowPowerMode: Bool?
    var thermalState: Int?
    /// "answer" or "rich": which text was streamed.
    var corpus: String?
    var osVersion: String?
    /// For TranscriptKit renderers: what the document held at the end.
    var content: [String: Int]?
}
