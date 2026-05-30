import MLX

/// Pure-MLX correlation layer.
/// Computes 49-channel local correlation cost volume (max_displacement=6, stride_2=2).
enum Correlation {

    /// Compute local correlation cost volume.
    /// - Parameters:
    ///   - feat1: [B, H, W, C] features from frame 1
    ///   - feat2: [B, H, W, C] features from frame 2
    ///   - maxDisplacement: Maximum displacement in pixels (default 6)
    ///   - stride2: Stride in displacement dimension (default 2)
    /// - Returns: [B, H, W, 49] correlation volume
    static func correlate(
        _ feat1: MLXArray,
        _ feat2: MLXArray,
        maxDisplacement: Int = 6,
        stride2: Int = 2
    ) -> MLXArray {
        let shape = feat1.shape
        let C = Float(shape[3])
        let H = shape[1]
        let W = shape[2]

        let d = maxDisplacement
        let feat2Padded = padded(
            feat2,
            widths: [IntOrPair((0, 0)), IntOrPair((d, d)), IntOrPair((d, d)), IntOrPair((0, 0))]
        )

        var planes = [MLXArray]()
        for dy in stride(from: -d, through: d, by: stride2) {
            for dx in stride(from: -d, through: d, by: stride2) {
                let sy = d + dy
                let sx = d + dx
                let shifted = feat2Padded[0..., sy ..< (sy + H), sx ..< (sx + W), 0...]
                let dot = MLX.sum(feat1 * shifted, axis: -1, keepDims: true) / C
                planes.append(dot)
            }
        }

        return MLX.concatenated(planes, axis: -1)
    }
}
