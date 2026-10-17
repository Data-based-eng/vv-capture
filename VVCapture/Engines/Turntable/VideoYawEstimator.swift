import AVFoundation
import CoreGraphics
import Foundation
import os

/// What the video analysis measured about the turntable's rotation.
struct VideoYawAnalysis: Sendable {
    /// Seconds into the video where rotation starts.
    var t0: Double
    /// Seconds where rotation ends.
    var t1: Double
    /// Angular velocity in degrees per second — measured from the marker when
    /// possible, otherwise the nominal speed the turntable was set to.
    var omegaDegPerSec: Double
    /// "video-marker" (measured) or "video-rpm" (nominal fallback).
    var method: String
    /// Sine-fit quality 0…1; 0 when the nominal speed was used.
    var confidence: Double
    /// Human-readable caveat for the capture log, if any.
    var warning: String?
}

enum YawError: LocalizedError {
    case noVideoTrack
    case videoTooShort
    case orbitVideoTooShort
    case noRotationDetected
    case frameEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "The recorded file has no video track."
        case .videoTooShort:
            "The video is too short to measure rotation."
        case .orbitVideoTooShort:
            "The orbit video is too short — walk around the product for at least a few seconds."
        case .noRotationDetected:
            "No turntable rotation was detected in the video. Make sure the table is turning while recording, with a few seconds of still footage before and after."
        case .frameEncodingFailed:
            "A video frame could not be saved."
        }
    }
}

/// Grabs one frame from the generator, awaiting its completion handler.
///
/// Cancellation-safe: the old `withCheckedThrowingContinuation` alone left
/// the continuation parked (and the awaiting task un-cancellable) until the
/// decoder happened to finish. On cancel we now ask the generator to drop its
/// queue, which fires the completion handler so the continuation resumes
/// promptly. The generator is used strictly serially by every caller, so
/// `cancelAllCGImageGeneration` can't clobber a sibling request.
/// AVAssetImageGenerator isn't Sendable, but this helper's lifecycle keeps it
/// confined: the caller creates it, it is used strictly serially, and only
/// `cancelAllCGImageGeneration()` crosses into the `@Sendable` onCancel
/// closure. The box documents that manual guarantee.
private final class UncheckedGeneratorBox: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    init(_ generator: AVAssetImageGenerator) { self.generator = generator }
}

func generatedCGImage(
    at time: CMTime,
    using generator: AVAssetImageGenerator
) async throws -> (CGImage, CMTime) {
    let box = UncheckedGeneratorBox(generator)
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, actualTime, error in
                if let image {
                    continuation.resume(returning: (image, actualTime))
                } else {
                    continuation.resume(throwing: error ?? YawError.frameEncodingFailed)
                }
            }
        }
    } onCancel: {
        box.generator.cancelAllCGImageGeneration()
    }
}

/// Recovers per-frame yaw from a turntable video.
///
/// The phone never moves, so the turntable's spin is the only motion in the
/// frame. Rotation onset/offset come from frame-to-frame luma differences
/// (with a 1 s-gap differencing fallback for slow turntables); angular
/// velocity comes from tracking a red/pink marker stuck on the plate rim — its
/// horizontal position follows a sine wave whose period is one revolution.
/// When the marker can't be measured, the nominal speed the turntable was set
/// to is used instead, clearly labelled "video-rpm".
struct YawEstimator: Sendable {
    private static let logger = Logger(subsystem: "com.visionvend.capture", category: "yaw")

    /// Frames between compared samples for the slow-rotation pass (~1 s at the
    /// 4 fps sampling rate).
    private static let slowGap = 4
    /// Runs separated by fewer below-threshold samples than this are merged
    /// into one rotation window (occlusion flicker, compression dips).
    private static let mergeGapFrames = 10

    /// - Parameter nominalRevSeconds: seconds per revolution the turntable was
    ///   set to in its app. Only used when the marker can't be measured.
    /// - Parameter onProgress: 0…1 over the analysis pass.
    func analyze(
        videoURL: URL,
        nominalRevSeconds: Double,
        onProgress: (Double) -> Void
    ) async throws -> VideoYawAnalysis {
        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration >= 10 else { throw YawError.videoTooShort }

        // Sample ~4 fps, downscaled. The generator reports the actual frame
        // time for each grab, so the series stays truthful even when the
        // decoder hands back a nearby frame.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        var times: [Double] = []
        var diffs: [Double] = []
        var slowTimes: [Double] = []
        var slowDiffs: [Double] = []
        var frameHistory: [[UInt8]] = []  // ring of the last `slowGap` frames
        var markerX: [(t: Double, x: Double)] = []
        var prevBytes: [UInt8] = []
        var samples = 0
        var grabFailures = 0
        var firstGrabError: Error?

        var t = 0.0
        let step = 0.25
        while t < duration {
            try Task.checkCancellation()
            let cg: CGImage
            let actual: CMTime
            do {
                // The old `try?` swallowed decoder failures, and the
                // `noRotationDetected` thrown below then blamed the turntable.
                // Record the real error so it can be surfaced.
                (cg, actual) = try await generatedCGImage(
                    at: CMTime(seconds: t, preferredTimescale: 600),
                    using: generator
                )
            } catch {
                if firstGrabError == nil { firstGrabError = error }
                grabFailures += 1
                t += step
                continue
            }
            guard let pixels = Self.pixels(of: cg) else {
                grabFailures += 1
                t += step
                continue
            }
            let at = CMTimeGetSeconds(actual)
            if let last = times.last, at <= last + 0.01 {
                t += step
                continue // Decoder returned a frame we already have.
            }
            samples += 1

            let bytes = pixels.bytes
            if prevBytes.count == bytes.count, !prevBytes.isEmpty {
                diffs.append(Self.meanAbsDiff(bytes, prevBytes))
                times.append(at)
                // M3: 1 s-gap diffs feed the slow-rotation fallback pass.
                if frameHistory.count == Self.slowGap {
                    let ref = frameHistory.removeFirst()
                    if ref.count == bytes.count {
                        slowDiffs.append(Self.meanAbsDiff(bytes, ref))
                        slowTimes.append(at)
                    }
                }
                frameHistory.append(bytes)
            } else {
                // First frame, or the frame size changed mid-stream: restart
                // the baselines WITHOUT recording a diff. The old code
                // injected a synthetic 0 here, which split the motion run at
                // the seam and could chop the rotation window in two.
                frameHistory = [bytes]
            }
            prevBytes = bytes

            if let centroid = Self.markerCentroid(pixels: pixels) {
                markerX.append((at, centroid.x))
            }

            if samples % 16 == 0 {
                onProgress(min(0.95, t / duration))
            }
            t += step
        }
        onProgress(1.0)

        // Motion onset/offset: the only thing moving is the turntable, so a
        // sustained rise above the video's own noise floor means rotation.
        // The floor is measured from the ends of the video, where the protocol
        // calls for still footage. If neither end is still, the floor lands at
        // motion level, nothing exceeds it, and the error below correctly asks
        // for still lead-in/tail.
        guard times.count >= 20 else {
            // Don't blame the turntable when the decoder never gave us frames.
            if let error = firstGrabError, grabFailures >= max(samples, 1) {
                throw error
            }
            throw YawError.noRotationDetected
        }
        guard let noiseFloor = Self.noiseFloor(diffs: diffs, times: times) else {
            throw YawError.noRotationDetected
        }
        // Clamped adaptive floors (Actimetrics): a fixed floor wrongly
        // excludes slow motion and is fooled by gain changes; an unbounded
        // floor absorbs still footage into the window.
        let threshold = max(noiseFloor * 4, 0.02)
        let walkGate = max(noiseFloor * 1.5, 0.02)
        let t0: Double
        let t1: Double
        if let w = Self.rotationWindow(diffs: diffs, strict: threshold, walkGate: walkGate, minRun: 5) {
            t0 = times[w.onset]
            t1 = times[w.offset]
        } else if let w = Self.slowRotationWindow(slowDiffs: slowDiffs, slowTimes: slowTimes) {
            // M3: slow turntables (90–120 s/rev) move the marker ~1 px between
            // adjacent 4 fps samples — at/below digitization noise — so the
            // adjacent-frame pass can never see them.
            Self.logger.info("Rotation found only via 1 s-gap differencing (slow turntable).")
            t0 = w.t0
            t1 = w.t1
        } else {
            throw YawError.noRotationDetected
        }
        guard t1 - t0 > 8 else { throw YawError.noRotationDetected }

        // Marker → angular velocity via sine fit on its horizontal position.
        let nominalOmega = 360 / max(nominalRevSeconds, 1)
        var omega = nominalOmega
        var method = "video-rpm"
        var confidence = 0.0
        var warning: String? = "The rim marker wasn't found, so angles use the rotation speed setting. For measured angles, stick a 2 cm square of bright red or pink tape on the turntable's rim."

        // Fit only on the motion window: the marker sits still in the lead-in
        // and tail, and those flat segments would bias the period.
        let motionMarkers = markerX.filter { $0.t >= t0 - 0.5 && $0.t <= t1 + 0.5 }
        // Coverage is measured over the motion window, not the whole video —
        // a long still lead-in used to dilute it below the 0.4 gate even when
        // the marker was visible for every rotation frame.
        let windowSamples = times.filter { $0 >= t0 - 0.5 && $0 <= t1 + 0.5 }.count
        let coverage = Double(motionMarkers.count) / Double(max(windowSamples, 1))
        if motionMarkers.count >= 30, coverage >= 0.4 {
            let xs = motionMarkers.map(\.x)
            let ts = motionMarkers.map(\.t)
            if let (period, r2) = Self.bestPeriod(times: ts, values: xs),
               r2 >= 0.9, period > 5 {
                omega = 360 / period
                method = "video-marker"
                confidence = r2
                warning = nil
                Self.logger.info("Measured rotation: \(period, privacy: .public)s/rev, R²=\(r2, privacy: .public)")
            } else {
                Self.logger.info("Marker fit too weak (R² below 0.9); falling back to nominal speed.")
            }
        } else {
            Self.logger.info("Marker seen in only \(motionMarkers.count, privacy: .public)/\(windowSamples, privacy: .public) motion-window samples; falling back to nominal speed.")
        }

        let coverageDeg = omega * (t1 - t0)
        if coverageDeg < 324 {
            let note = "The video covers only \(Int(coverageDeg))° of rotation — record at least one full turn."
            warning = [warning, note].compactMap { $0 }.joined(separator: " ")
        }

        return VideoYawAnalysis(
            t0: t0,
            t1: t1,
            omegaDegPerSec: omega,
            method: method,
            confidence: confidence,
            warning: warning
        )
    }

    // MARK: - Pixel helpers

    private struct SmallPixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]  // BGRA
    }

    /// Draws the image into a caller-owned BGRA buffer so channel order is known.
    ///
    /// The bitmap info matters: `noneSkipFirst | byteOrder32Little` lays bytes
    /// out as B,G,R,X in memory. (`noneSkipLast` would give X,B,G,R — a real
    /// bug that once made every red pixel test read the green channel.)
    private static func pixels(of cg: CGImage) -> SmallPixels? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return SmallPixels(width: w, height: h, bytes: data)
    }

    /// Mean absolute difference across all three channels — motion in any
    /// color registers. (Green-only differencing nearly missed a pure-red
    /// marker.)
    private static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            sum += Double(abs(Int(a[i]) - Int(b[i])))
            sum += Double(abs(Int(a[i + 1]) - Int(b[i + 1])))
            sum += Double(abs(Int(a[i + 2]) - Int(b[i + 2])))
        }
        return sum / Double(3 * (a.count / 4))
    }

    /// Centroid of the largest red/pink blob — the rim marker. Returns nil
    /// when no plausible blob is present.
    ///
    /// M1: this used to average ALL red pixels, so a red shirt or product
    /// dragged the mean off the marker and could alias the sine fit to a
    /// wrong period that still cleared R² ≥ 0.9. The binary red mask is now
    /// labeled with a small flood-fill connected-components pass
    /// (4-connectivity, Vision is not a dependency of this target) and only
    /// the LARGEST blob's centroid is returned — label 0 is background, and
    /// selection is by explicit max area, never by label order. Frames where
    /// the largest blob is far bigger than any plausible marker (red
    /// shirt/product) are rejected outright rather than fitted.
    ///
    /// The old absolute thresholds (r > 140, g < 110, r − max(g,b) > 50) died
    /// under dim indoor light. Redness is now a ratio test, which is
    /// intensity-invariant: r must dominate g and b by 1.6× (5r > 8g, 5r > 8b
    /// in integer math), with a small absolute floor to keep black-level noise
    /// out.
    private static func markerCentroid(pixels: SmallPixels) -> CGPoint? {
        let w = pixels.width, h = pixels.height, n = w * h
        let bytes = pixels.bytes
        var mask = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let b = Int(bytes[i * 4])
            let g = Int(bytes[i * 4 + 1])
            let r = Int(bytes[i * 4 + 2])
            mask[i] = r > 50 && 5 * r > 8 * g && 5 * r > 8 * b
        }

        var visited = [Bool](repeating: false, count: n)
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        var bestArea = 0
        var bestSumX = 0.0, bestSumY = 0.0
        for seed in 0..<n where mask[seed] && !visited[seed] {
            visited[seed] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            var area = 0
            var sumX = 0.0, sumY = 0.0
            while let p = stack.popLast() {
                area += 1
                sumX += Double(p % w)
                sumY += Double(p / w)
                let x = p % w
                if x > 0 {
                    let q = p - 1
                    if mask[q], !visited[q] { visited[q] = true; stack.append(q) }
                }
                if x < w - 1 {
                    let q = p + 1
                    if mask[q], !visited[q] { visited[q] = true; stack.append(q) }
                }
                if p >= w {
                    let q = p - w
                    if mask[q], !visited[q] { visited[q] = true; stack.append(q) }
                }
                if p < n - w {
                    let q = p + w
                    if mask[q], !visited[q] { visited[q] = true; stack.append(q) }
                }
            }
            if area > bestArea {
                bestArea = area
                bestSumX = sumX
                bestSumY = sumY
            }
        }
        // A 2 cm tape square is a few hundred px at 480×270; anything above
        // ~12% of the frame is a red shirt or product, not the marker.
        guard bestArea >= 20, bestArea <= 15_000 else { return nil }
        return CGPoint(x: bestSumX / Double(bestArea), y: bestSumY / Double(bestArea))
    }

    // MARK: - Motion onset/offset

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .infinity }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// Noise floor from the still lead-in/tail the capture protocol calls for.
    /// Nil when the measurement is degenerate (no usable samples).
    private static func noiseFloor(diffs: [Double], times: [Double]) -> Double? {
        guard let first = times.first, let last = times.last else { return nil }
        let head = median(zip(times, diffs).filter { $0.0 < first + 2.5 }.map(\.1))
        let tail = median(zip(times, diffs).filter { $0.0 > last - 2.5 }.map(\.1))
        let floor = min(head, tail)
        return floor.isFinite ? floor : nil
    }

    /// Longest sustained above-threshold motion run, with brief dips merged
    /// and edges walked back/forward over the lenient gate. Returns index
    /// bounds into the diffs/times arrays.
    ///
    /// M4: onset used to be the FIRST 5-frame run, so a hand nudging the
    /// product during the lead-in was misdetected as rotation onset and
    /// shifted every recorded yaw by a constant. The rotation is always the
    /// longest sustained run; nudges and AGC hunting are transient. (Ties go
    /// to the earliest run.)
    ///
    /// M2: the edge walk-back/forward gate is clamped like the main
    /// threshold — a near-zero noise floor used to absorb still footage into
    /// the window, rotating every recorded yaw.
    private static func rotationWindow(
        diffs: [Double],
        strict threshold: Double,
        walkGate: Double,
        minRun: Int
    ) -> (onset: Int, offset: Int)? {
        // Collect runs of >= minRun consecutive above-threshold samples.
        // (Was `diffs.count > run`; the strict `>` was an off-by-one that
        // rejected a run exactly `run` long — now `>=`.)
        var runs: [(Int, Int)] = []
        var i = 0
        while i < diffs.count {
            guard diffs[i] > threshold else { i += 1; continue }
            var j = i + 1
            while j < diffs.count, diffs[j] > threshold { j += 1 }
            if j - i >= minRun { runs.append((i, j - 1)) }
            i = j
        }
        guard !runs.isEmpty else { return nil }
        // Merge runs split by brief dips (occlusion flicker, compression)
        // so one rotation window isn't chopped into pieces.
        var merged: [(Int, Int)] = [runs[0]]
        for run in runs.dropFirst() {
            if run.0 - merged[merged.count - 1].1 <= mergeGapFrames {
                merged[merged.count - 1].1 = run.1
            } else {
                merged.append(run)
            }
        }
        guard let longest = merged.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }) else { return nil }
        // The strict run starts late (it needs minRun consecutive hits). Walk
        // back/forward over the lenient gate to find the true edges — a
        // constant t0 offset would otherwise rotate every recorded yaw.
        var onset = longest.0
        while onset > 0, diffs[onset - 1] > walkGate { onset -= 1 }
        var offset = longest.1
        while offset < diffs.count - 1, diffs[offset + 1] > walkGate { offset += 1 }
        guard offset > onset else { return nil }
        return (onset, offset)
    }

    /// Second-chance detection for slow turntables (90–120 s/rev). At those
    /// speeds the marker moves ~1 px between adjacent 4 fps samples —
    /// at/below ±1–2 LSB digitization noise — so adjacent-frame differencing
    /// cannot work (M3). Differencing frames ~1 s apart restores a healthy
    /// motion signal; the second pass uses a lower threshold and a longer
    /// minimum run to stay honest.
    private static func slowRotationWindow(
        slowDiffs: [Double],
        slowTimes: [Double]
    ) -> (t0: Double, t1: Double)? {
        guard slowDiffs.count >= 20,
              let floor = Self.noiseFloor(diffs: slowDiffs, times: slowTimes)
        else { return nil }
        let threshold = max(floor * 2.5, 0.02)
        let walkGate = max(floor * 1.3, 0.02)
        guard let w = Self.rotationWindow(
            diffs: slowDiffs, strict: threshold, walkGate: walkGate, minRun: 8
        ) else { return nil }
        return (slowTimes[w.onset], slowTimes[w.offset])
    }

    // MARK: - Sine-fit angular velocity

    /// Finds the revolution period by fitting x(t) = A·sin(2πt/T) + B·cos(2πt/T) + C
    /// over candidate periods, then refining the best with golden-section
    /// search (the grid alone is ~12% spaced, which can leave several percent
    /// of period error). Returns the best (period, R²).
    private static func bestPeriod(times: [Double], values: [Double]) -> (Double, Double)? {
        var best: (Double, Double)?
        for k in 0..<40 {
            let period = 12 * pow(900.0 / 12.0, Double(k) / 39.0)
            let (a, b, _, r2) = fitSine(times: times, values: values, period: period)
            // A real marker swings several pixels; a near-zero amplitude is noise.
            guard hypot(a, b) > 2 else { continue }
            if r2 > (best?.1 ?? 0) {
                best = (period, r2)
            }
        }
        guard let (p0, _) = best else { return nil }
        var lo = p0 / 1.15, hi = p0 * 1.15
        let gr = (sqrt(5) - 1) / 2
        var c = hi - gr * (hi - lo), d = lo + gr * (hi - lo)
        var rc = fitSine(times: times, values: values, period: c).3
        var rd = fitSine(times: times, values: values, period: d).3
        for _ in 0..<24 {
            if rc > rd {
                hi = d; d = c; rd = rc
                c = hi - gr * (hi - lo)
                rc = fitSine(times: times, values: values, period: c).3
            } else {
                lo = c; c = d; rc = rd
                d = lo + gr * (hi - lo)
                rd = fitSine(times: times, values: values, period: d).3
            }
        }
        let period = (lo + hi) / 2
        let (aFinal, bFinal, _, r2) = fitSine(times: times, values: values, period: period)
        // The amplitude gate was only checked on the coarse grid; a degenerate
        // refinement can collapse the amplitude while keeping R² high, so
        // re-check here and reject the fit instead of measuring noise.
        guard hypot(aFinal, bFinal) > 2 else { return nil }
        return (period, r2)
    }

    private static func fitSine(times: [Double], values: [Double], period: Double) -> (Double, Double, Double, Double) {
        let w = 2 * Double.pi / period
        var sSS = 0.0, sCC = 0.0, sSC = 0.0, sS = 0.0, sC = 0.0
        var sSX = 0.0, sCX = 0.0, sX = 0.0
        let n = Double(times.count)
        var mean = 0.0
        for i in 0..<times.count {
            let s = sin(w * times[i]), c = cos(w * times[i]), x = values[i]
            sSS += s * s; sCC += c * c; sSC += s * c; sS += s; sC += c
            sSX += s * x; sCX += c * x; sX += x
            mean += x
        }
        mean /= n

        // Solve the 3×3 normal equations by Gaussian elimination.
        var m = [
            [sSS, sSC, sS, sSX],
            [sSC, sCC, sC, sCX],
            [sS, sC, n, sX]
        ]
        for col in 0..<3 {
            var piv = col
            for row in (col + 1)..<3 where abs(m[row][col]) > abs(m[piv][col]) {
                piv = row
            }
            m.swapAt(col, piv)
            let div = m[col][col]
            guard abs(div) > 1e-12 else { return (0, 0, 0, 0) }
            for row in 0..<3 where row != col {
                let factor = m[row][col] / div
                for k in col..<4 { m[row][k] -= factor * m[col][k] }
            }
        }
        let a = m[0][3] / m[0][0], b = m[1][3] / m[1][1], c = m[2][3] / m[2][2]

        var ssRes = 0.0, ssTot = 0.0
        for i in 0..<times.count {
            let pred = a * sin(w * times[i]) + b * cos(w * times[i]) + c
            ssRes += (values[i] - pred) * (values[i] - pred)
            ssTot += (values[i] - mean) * (values[i] - mean)
        }
        let r2 = ssTot > 1e-9 ? max(0, 1 - ssRes / ssTot) : 0
        return (a, b, c, r2)
    }
}
