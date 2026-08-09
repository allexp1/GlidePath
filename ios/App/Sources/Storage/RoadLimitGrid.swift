import Foundation
import ZonexploCore

/// How the phone indexes hundreds of thousands of speed limits so it can find
/// the handful under the car in a millisecond.
///
/// Cameras get away with a bounding-box scan over indexed latitude and
/// longitude because a country holds a few thousand of them. Road limits are
/// three orders of magnitude more numerous, and the same query degenerates into
/// reading every road in a band of latitude stretching across the country.
///
/// So limits are filed by grid cell. Each stored row knows the cell its midpoint
/// falls in, a lookup asks only for the cells around the driver, and SQLite
/// answers straight from the index. Two things make that correct:
///
/// - **Rows are chunked to a bounded length before storage**, so a row's extent
///   from its midpoint is bounded too. Without it, one 30 km motorway way would
///   sit in a single cell and be invisible from every other cell it runs
///   through.
/// - **The lookup asks for one cell more than it needs.** A chunk whose midpoint
///   sits at the edge of a cell still reaches into the next one, and a cell is
///   wider than a chunk is long, so a single ring of margin covers it.
enum RoadLimitGrid {
    /// Cell size in degrees. About 2.2 km north-south everywhere, and 1.3 km
    /// east-west at Lithuanian latitudes.
    ///
    /// The trade is rows-per-cell against cells-per-query. Smaller cells read
    /// less per lookup but multiply the number of index probes and force a
    /// larger margin ring; this size keeps a typical urban lookup to a few
    /// hundred rows across at most sixteen cells.
    static let cellDegrees = 0.02

    /// The longest a stored chunk may be. Comfortably under the cell size, which
    /// is what makes the single-cell margin sufficient.
    static let maximumChunkMeters: Double = 400

    static func cell(for coordinate: Coordinate) -> String {
        let latitudeIndex = Int(floor(coordinate.latitude / cellDegrees))
        let longitudeIndex = Int(floor(coordinate.longitude / cellDegrees))
        return "\(latitudeIndex):\(longitudeIndex)"
    }

    /// Every cell that could hold a chunk within `radiusMeters` of `coordinate`,
    /// including the margin ring.
    static func cells(around coordinate: Coordinate, radiusMeters: Double) -> [String] {
        let box = BoundingBox(around: coordinate, radiusMeters: radiusMeters)

        let minLatitudeIndex = Int(floor(box.minLatitude / cellDegrees)) - 1
        let maxLatitudeIndex = Int(floor(box.maxLatitude / cellDegrees)) + 1
        let minLongitudeIndex = Int(floor(box.minLongitude / cellDegrees)) - 1
        let maxLongitudeIndex = Int(floor(box.maxLongitude / cellDegrees)) + 1

        var keys: [String] = []
        keys.reserveCapacity(
            (maxLatitudeIndex - minLatitudeIndex + 1) * (maxLongitudeIndex - minLongitudeIndex + 1)
        )

        for latitude in minLatitudeIndex...maxLatitudeIndex {
            for longitude in minLongitudeIndex...maxLongitudeIndex {
                keys.append("\(latitude):\(longitude)")
            }
        }
        return keys
    }

    /// One stored row: a bounded piece of one OpenStreetMap way.
    struct Chunk {
        let coordinates: [Coordinate]
        let cell: String
    }

    /// Cuts a way's polyline into chunks no longer than `maximumChunkMeters`.
    ///
    /// Consecutive chunks share their boundary point rather than butting up
    /// against each other. Without the overlap a driver sitting exactly on the
    /// join would project onto neither piece and the road would blink out; one
    /// duplicated coordinate is a cheap price for it never happening.
    ///
    /// A single segment longer than the limit is left whole. Splitting it would
    /// mean inventing coordinates that are not in the source data, and an
    /// 800 m straight with no intermediate node is a real thing on a motorway.
    static func chunk(_ coordinates: [Coordinate]) -> [Chunk] {
        guard coordinates.count >= 2 else { return [] }

        var chunks: [Chunk] = []
        var currentCoordinates: [Coordinate] = [coordinates[0]]
        var currentLength: Double = 0

        for index in 1..<coordinates.count {
            let step = coordinates[index - 1].distance(to: coordinates[index])
            currentCoordinates.append(coordinates[index])
            currentLength += step

            // Never close on the final point. Doing so would leave a one-point
            // remainder, which is not a polyline and would silently drop the
            // end of the road.
            let isLast = index == coordinates.count - 1
            if currentLength >= maximumChunkMeters, !isLast {
                chunks.append(makeChunk(currentCoordinates))
                currentCoordinates = [coordinates[index]]
                currentLength = 0
            }
        }

        // Always at least two points here: the accumulator starts with the
        // first coordinate, the loop appends before it ever closes a chunk, and
        // closing on the last point is excluded above.
        chunks.append(makeChunk(currentCoordinates))
        return chunks
    }

    private static func makeChunk(_ coordinates: [Coordinate]) -> Chunk {
        Chunk(coordinates: coordinates, cell: cell(for: midpoint(of: coordinates)))
    }

    /// The coordinate half way along the chunk, which is what decides its cell.
    /// The midpoint by distance rather than the middle element: a chunk with a
    /// dense bend at one end has its element-wise middle sitting in the bend.
    private static func midpoint(of coordinates: [Coordinate]) -> Coordinate {
        guard let path = RoadPath(coordinates: coordinates) else {
            return coordinates[coordinates.count / 2]
        }
        return path.coordinate(atDistance: path.totalDistance / 2)
    }
}
