import MLX

/// Pure-MLX bilinear grid sampling (NHWC).
/// Equivalent to PyTorch F.grid_sample(mode='bilinear', padding_mode='zeros', align_corners=True).
enum GridSample {

    /// Bilinear grid sampling.
    /// - Parameters:
    ///   - x: [B, H, W, C] input feature map
    ///   - grid: [B, gH, gW, 2] sampling grid with values in [-1, 1]
    /// - Returns: [B, gH, gW, C] sampled output
    static func sample(_ x: MLXArray, grid: MLXArray) -> MLXArray {
        let shape = x.shape
        let B = shape[0]
        let H = shape[1]
        let W = shape[2]
        let C = shape[3]
        let gShape = grid.shape
        let gH = gShape[1]
        let gW = gShape[2]

        // Unnormalize: [-1, 1] → [0, W-1] / [0, H-1] (align_corners=True)
        let ix = (grid[0..., 0..., 0..., 0..<1] + 1.0) * Float(W - 1) / 2.0
        let iy = (grid[0..., 0..., 0..., 1..<2] + 1.0) * Float(H - 1) / 2.0

        let ix0 = MLX.floor(ix).asType(.int32)
        let iy0 = MLX.floor(iy).asType(.int32)
        let ix1 = ix0 + 1
        let iy1 = iy0 + 1

        let wx = ix - ix0.asType(.float32)
        let wy = iy - iy0.asType(.float32)

        func inBounds(_ iy: MLXArray, _ ix: MLXArray) -> MLXArray {
            let valid = (iy .>= 0) & (iy .< H) & (ix .>= 0) & (ix .< W)
            return valid.asType(.float32)
        }

        func gather(_ iy: MLXArray, _ ix: MLXArray) -> MLXArray {
            let mask = inBounds(iy, ix)
            let iyc = MLX.clip(iy, min: 0, max: H - 1)
            let ixc = MLX.clip(ix, min: 0, max: W - 1)

            let batchIdx = MLXArray(0 ..< B).reshaped([B, 1, 1, 1])
            let linearIdx = batchIdx * (H * W) + iyc * W + ixc
            let xFlat = x.reshaped([B * H * W, C])
            let idxFlat = linearIdx.reshaped([-1])
            let gathered = xFlat[idxFlat].reshaped([B, gH, gW, C])
            return gathered * mask
        }

        let nw = gather(iy0, ix0)
        let ne = gather(iy0, ix1)
        let sw = gather(iy1, ix0)
        let se = gather(iy1, ix1)

        return nw * (1 - wx) * (1 - wy) +
               ne * wx * (1 - wy) +
               sw * (1 - wx) * wy +
               se * wx * wy
    }

    /// Create a base sampling grid with normalized coordinates [-1, 1].
    static func makeBaseGrid(height H: Int, width W: Int) -> MLXArray {
        let gx = MLXArray.linspace(Float(-1.0), Float(1.0), count: W)
        let gy = MLXArray.linspace(Float(-1.0), Float(1.0), count: H)
        let grids = meshGrid([gy, gx], indexing: .ij)
        let gyGrid = grids[0]
        let gxGrid = grids[1]
        let grid = stacked([gxGrid, gyGrid], axis: -1)
        return grid.expandedDimensions(axis: 0)
    }

    /// Backward warp features using optical flow.
    /// - Parameters:
    ///   - features: [B, H, W, C] input feature map
    ///   - flow: [B, H, W, 2] optical flow in pixels
    /// - Returns: [B, H, W, C] warped features
    static func backwardWarp(_ features: MLXArray, flow: MLXArray) -> MLXArray {
        let shape = features.shape
        let H = shape[1]
        let W = shape[2]

        let baseGrid = makeBaseGrid(height: H, width: W)

        let flowNormX = flow[0..., 0..., 0..., 0..<1] * (2.0 / Float(max(W - 1, 1)))
        let flowNormY = flow[0..., 0..., 0..., 1..<2] * (2.0 / Float(max(H - 1, 1)))
        let flowNorm = MLX.concatenated([flowNormX, flowNormY], axis: -1)

        let grid = baseGrid + flowNorm
        return sample(features, grid: grid)
    }
}
