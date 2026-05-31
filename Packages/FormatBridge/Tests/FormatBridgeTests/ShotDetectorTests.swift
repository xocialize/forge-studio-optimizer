import Testing
@testable import FormatBridge

@Suite("ShotDetector (Step 2 per-shot)")
struct ShotDetectorTests {

    /// A one-hot histogram (all mass in bin `b` of `n`) — a maximally distinct
    /// "scene". Consecutive identical ones have distance 0; different ones, 1.
    private func sig(_ b: Int, _ n: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: n); v[b] = 1; return v
    }

    /// `count` frames of scene `b`.
    private func scene(_ b: Int, _ count: Int) -> [[Float]] {
        (0 ..< count).map { _ in sig(b) }
    }

    @Test("distance: identical = 0, disjoint = 1, half-overlap = 0.5")
    func distance() {
        #expect(ShotDetector.distance(sig(0), sig(0)) == 0)
        #expect(ShotDetector.distance(sig(0), sig(1)) == 1)
        #expect(abs(ShotDetector.distance([0.5, 0.5, 0, 0], [0, 0.5, 0.5, 0]) - 0.5) < 1e-6)
    }

    @Test("three abrupt scenes → three shots at the right boundaries")
    func threeScenes() {
        let sigs = scene(0, 20) + scene(1, 20) + scene(2, 20)
        let det = ShotDetector(threshold: 0.35, minShotFrames: 5)
        #expect(det.boundaries(signatures: sigs) == [0, 20, 40])
        let shots = det.shots(signatures: sigs)
        #expect(shots == [0 ..< 20, 20 ..< 40, 40 ..< 60])
    }

    @Test("single continuous scene → one shot")
    func oneScene() {
        let det = ShotDetector()
        #expect(det.shots(signatures: scene(3, 50)) == [0 ..< 50])
    }

    @Test("minShotFrames suppresses cuts that come too soon")
    func minShotMerge() {
        // Scene 0 (30), then a 3-frame flash of scene 1, then back to scene 0.
        let sigs = scene(0, 30) + scene(1, 3) + scene(0, 30)
        // minShotFrames 12: the flash at 30 starts a shot, but the return at 33
        // is < 12 frames later → suppressed, so only one cut survives (at 30).
        let det = ShotDetector(threshold: 0.35, minShotFrames: 12)
        #expect(det.boundaries(signatures: sigs) == [0, 30])
    }

    @Test("gradual drift below threshold is not a cut")
    func gradualDrift() {
        // Slowly rotate mass between two bins — each step is small (< threshold).
        var sigs: [[Float]] = []
        for i in 0 ..< 40 {
            let t = Float(i) / 39
            sigs.append([1 - t, t, 0, 0, 0, 0, 0, 0])
        }
        let det = ShotDetector(threshold: 0.35, minShotFrames: 5)
        #expect(det.shots(signatures: sigs) == [0 ..< 40])   // one shot, no false cut
    }

    @Test("empty input → no shots")
    func empty() {
        #expect(ShotDetector().shots(signatures: []) == [])
    }
}
