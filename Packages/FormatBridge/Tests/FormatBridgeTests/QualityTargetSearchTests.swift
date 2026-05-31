import Testing
@testable import FormatBridge

/// Pure-algorithm tests for the VMAF-targeted search — synthetic monotone
/// oracle, no encoder, no VMAF. De-risks the search logic in isolation.
@Suite("QualityTargetSearch (Step 1 algorithm)")
struct QualityTargetSearchTests {

    /// Linear oracle: VMAF 80 at q=0 → 100 at q=1.
    private func linear(_ q: Float) -> Double { 80.0 + 20.0 * Double(q) }

    @Test("finds the lowest quality that clears the target")
    func midRange() async {
        let search = QualityTargetSearch(targetScore: 95, slack: 0.5)   // accept 94.5
        let r = await search.search { self.linear($0) }
        // 80 + 20q >= 94.5  →  q >= 0.725
        #expect(r.metTarget)
        #expect(r.achievedScore >= 94.5)
        #expect(r.quality >= 0.70 && r.quality <= 0.80)
        #expect(r.probeCount <= search.maxProbes)
        // It must be the *lowest*: a notch below should miss the target.
        #expect(self.linear(r.quality - 0.05) < 94.5)
    }

    @Test("floor already meets target → take the smallest quality, 2 probes")
    func floorMeets() async {
        let search = QualityTargetSearch(targetScore: 80, slack: 0.5)   // accept 79.5
        let r = await search.search { self.linear($0) }                // linear(0.1)=82 ≥ 79.5
        #expect(r.metTarget)
        #expect(r.quality == search.qualityRange.lowerBound)
        #expect(r.probeCount == 2)   // ceiling probe + floor probe, then return
    }

    @Test("target unreachable → return the ceiling, metTarget=false, 1 probe")
    func unreachable() async {
        let search = QualityTargetSearch(targetScore: 105, slack: 0.5)  // accept 104.5 > 100
        let r = await search.search { self.linear($0) }
        #expect(!r.metTarget)
        #expect(r.quality == search.qualityRange.upperBound)
        #expect(r.probeCount == 1)   // ceiling probe fails → bail immediately
    }

    @Test("non-linear (step) oracle still converges to the boundary")
    func stepOracle() async {
        // VMAF jumps from 90 to 99 at q = 0.5.
        let search = QualityTargetSearch(targetScore: 95, slack: 0.0, resolution: 0.02)
        let r = await search.search { (q: Float) in q < 0.5 ? 90.0 : 99.0 }
        #expect(r.metTarget)
        #expect(r.achievedScore == 99.0)
        // Smallest acceptable q is just at/above 0.5.
        #expect(r.quality >= 0.5 && r.quality <= 0.5 + search.resolution * 2)
    }

    @Test("respects the probe cap")
    func probeCap() async {
        let search = QualityTargetSearch(targetScore: 95, slack: 0.0,
                                         resolution: 0.0001, maxProbes: 4)
        let r = await search.search { self.linear($0) }
        #expect(r.probeCount <= 4)
    }
}
