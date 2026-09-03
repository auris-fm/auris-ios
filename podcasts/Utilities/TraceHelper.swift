import FirebasePerformance
import FirebaseCore
import Foundation
import PocketCastsUtils

class TraceHelper: TraceHandlingProtocol {
    func beginTracing(eventName: String) -> AnyObject? {
        // TEMPORARY DEV-GUARD: Performance traces crash when no default Firebase app
        // exists (e.g. dev builds with a stub GoogleService-Info.plist that skip
        // FirebaseApp.configure()). FIRPerformance silently no-ops via this early
        // return so lazy init (PodcastDataManager caches, PlaybackManager) doesn't throw.
        guard FirebaseApp.app() != nil else { return nil }

        return Performance.startTrace(name: eventName)
    }

    func endTracing(trace: AnyObject) {
        guard let trace = trace as? Trace else { return }

        trace.stop()
    }
}
