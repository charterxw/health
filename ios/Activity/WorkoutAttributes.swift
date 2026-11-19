import ActivityKit
import Foundation

struct WorkoutAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var workout: WorkoutSnapshot
    }
    let sessionID: String
}
