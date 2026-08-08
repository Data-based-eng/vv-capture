import simd

/// Voxel-hashed point accumulator.
///
/// Points are binned into a fixed grid and averaged per cell rather than stored
/// raw. That does three jobs at once: memory stays bounded no matter how long the
/// scan runs, repeated observations of the same surface average out sensor noise,
/// and the output is already uniformly sampled — which is what a meshing pass
/// wants as input.
struct DepthPointCloud: Sendable {

    /// Edge length of one voxel, in metres.
    ///
    /// 1.5 mm is chosen against the sensor rather than arbitrarily: TrueDepth's
    /// lateral sample spacing is roughly 0.5 mm at 30 cm, so this bins ~3×3
    /// samples per cell — enough averaging to suppress noise without erasing
    /// detail the sensor actually resolved.
    static let defaultVoxelSize: Float = 0.0015

    private struct Cell {
        var sum: SIMD3<Float>
        var count: Int32
    }

    let voxelSize: Float
    private var cells: [SIMD3<Int32>: Cell] = [:]
    private var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    init(voxelSize: Float = DepthPointCloud.defaultVoxelSize) {
        self.voxelSize = voxelSize
    }

    var pointCount: Int { cells.count }

    var isEmpty: Bool { cells.isEmpty }

    /// Axis-aligned bounds of everything observed so far, nil while empty.
    var bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
        cells.isEmpty ? nil : (minimum, maximum)
    }

    /// Bounding box dimensions in metres — the quickest sanity check that the
    /// metric scale is right, since it can be compared to a ruler.
    var dimensions: SIMD3<Float>? {
        guard let bounds else { return nil }
        return bounds.maximum - bounds.minimum
    }

    mutating func insert(_ positions: [SIMD3<Float>]) {
        for position in positions { insert(position) }
    }

    mutating func insert(_ position: SIMD3<Float>) {
        let key = SIMD3<Int32>(
            Int32((position.x / voxelSize).rounded(.down)),
            Int32((position.y / voxelSize).rounded(.down)),
            Int32((position.z / voxelSize).rounded(.down))
        )

        if var existing = cells[key] {
            existing.sum += position
            existing.count += 1
            cells[key] = existing
        } else {
            cells[key] = Cell(sum: position, count: 1)
        }

        minimum = simd_min(minimum, position)
        maximum = simd_max(maximum, position)
    }

    /// Cell centroids — the actual output of the scan.
    var points: [SIMD3<Float>] {
        cells.values.map { $0.sum / Float($0.count) }
    }

    /// A bounded subsample for live rendering. Drawing 400k points every frame
    /// costs more than it tells the user.
    func sampledPoints(limit: Int) -> [SIMD3<Float>] {
        guard cells.count > limit else { return points }
        let step = cells.count / limit
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(limit)
        for (index, cell) in cells.values.enumerated() where index % step == 0 {
            result.append(cell.sum / Float(cell.count))
            if result.count == limit { break }
        }
        return result
    }

    /// Drops cells seen only once. A surface genuinely observed by the sensor gets
    /// hit repeatedly as the device moves; single hits are overwhelmingly noise.
    mutating func pruneSingleObservations() {
        cells = cells.filter { $0.value.count > 1 }
        recomputeBounds()
    }

    private mutating func recomputeBounds() {
        minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for cell in cells.values {
            let centroid = cell.sum / Float(cell.count)
            minimum = simd_min(minimum, centroid)
            maximum = simd_max(maximum, centroid)
        }
    }
}
