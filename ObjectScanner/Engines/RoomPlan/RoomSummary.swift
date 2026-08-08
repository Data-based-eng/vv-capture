import Foundation
import RoomPlan
import simd

/// What a finished room turned out to contain.
///
/// RoomPlan is the one engine that knows what it built — it classified every
/// surface — so it is worth carrying that through to the library instead of
/// showing a bare file name.
struct RoomSummary: Sendable {
    let walls: Int
    let doors: Int
    let windows: Int
    let openings: Int
    let objects: Int

    /// Overall extent of the room in millimetres, or nil if no surface was
    /// captured. Real metres: RoomPlan is built on ARKit world tracking.
    let dimensionsMillimetres: [Int]?

    init(room: CapturedRoom) {
        walls = room.walls.count
        doors = room.doors.count
        windows = room.windows.count
        openings = room.openings.count
        objects = room.objects.count

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var sawCorner = false

        // Walls and floors bound the room; furniture sits inside them, so adding
        // objects here could only ever produce the same box or a wrong one.
        for surface in room.walls + room.floors {
            let half = surface.dimensions / 2
            // A surface's local frame is its plane: extent in x and y, nothing in z.
            for x in [-half.x, half.x] {
                for y in [-half.y, half.y] {
                    let world = surface.transform * SIMD4<Float>(x, y, 0, 1)
                    let point = SIMD3<Float>(world.x, world.y, world.z)
                    minimum = simd_min(minimum, point)
                    maximum = simd_max(maximum, point)
                    sawCorner = true
                }
            }
        }

        guard sawCorner else {
            dimensionsMillimetres = nil
            return
        }
        let extent = maximum - minimum
        dimensionsMillimetres = [extent.x, extent.y, extent.z].map { Int(($0 * 1000).rounded()) }
    }

    /// One line for the library row, listing only what was actually found.
    var text: String {
        var parts: [String] = ["\(walls) duvar"]
        if doors > 0 { parts.append("\(doors) kapı") }
        if windows > 0 { parts.append("\(windows) pencere") }
        if openings > 0 { parts.append("\(openings) geçiş") }
        if objects > 0 { parts.append("\(objects) nesne") }
        return parts.joined(separator: " · ")
    }
}
