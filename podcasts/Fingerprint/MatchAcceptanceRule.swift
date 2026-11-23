import Foundation

/// One ranked candidate from a matcher: where it sits in the reference, and how well it matched.
struct WindowMatch {
    let referenceTime: Double
    let score: Float
}

/// How a path decides that a matcher's best candidate is trustworthy: the floor
/// a score must clear, how large a lead it needs, and which candidate counts as
/// the rival it must beat.
///
/// The two sources served by this code answer "which rival" differently, so it is
/// a rule rather than a set of constants threaded through the loop. Transcript
/// sync compares against the immediate runner-up, as it always has. Auris compares
/// against the best candidate more than 2s away, because neighbouring reference
/// windows are the same audio shifted slightly and always score alike — a nearby
/// rival would suppress real matches while telling us nothing about ambiguity.
struct MatchAcceptanceRule {
    let scoreThreshold: Float
    let anchorScoreThreshold: Float
    let dominanceGap: Float
    let maxResults: Int
    /// Which rival the lead is measured against.
    let rival: Rival

    enum Rival {
        /// The immediate runner-up: neighbouring reference windows that score alike
        /// suggest the winner is not distinctive.
        case runnerUp
        /// The best candidate more than 2s away. Used for the Auris endpoint, where
        /// neighbouring windows are the same audio a moment later and always score
        /// alike, so a nearby rival would suppress real matches and prove nothing.
        case distant
    }

    /// The score this candidate must beat, or nil when the rule cannot establish one
    /// — an unconfirmable window, which fails closed.
    func rivalScore(in matches: [WindowMatch], best: WindowMatch) -> Float? {
        switch rival {
        case .runnerUp:
            return matches.dropFirst().first?.score ?? 0
        case .distant:
            return matches
                .dropFirst()
                .filter {
                    abs($0.referenceTime - best.referenceTime) > FingerprintConstants.aurisDistantCandidateSeconds
                }
                .map(\.score)
                .max()
        }
    }

    /// Why a candidate was not trusted. Named rather than a bare Bool so the debug
    /// overlay can tell "matcher fired but we didn't trust it" apart by cause.
    enum Rejection: Error {
        case scoreBelowFloor
        case noDistantCandidate
        case leadTooSmall
    }

    /// Whether this candidate is trustworthy enough to build a mapping on, and if not,
    /// why. The streaming loop and the fixture tests both call this, so a change to the
    /// rule cannot leave the tests validating a copy of it.
    func verdict(for matches: [WindowMatch]) -> Result<WindowMatch, Rejection> {
        guard let best = matches.first, best.score >= scoreThreshold else {
            return .failure(.scoreBelowFloor)
        }
        guard let rival = rivalScore(in: matches, best: best) else {
            return .failure(.noDistantCandidate)
        }
        guard best.score - rival >= dominanceGap else {
            return .failure(.leadTooSmall)
        }
        return .success(best)
    }

    /// Transcript sync's rule, unchanged from when the values were read inline.
    static let transcript = MatchAcceptanceRule(
        scoreThreshold: FingerprintConstants.matchScoreThreshold,
        anchorScoreThreshold: FingerprintConstants.driftAnchorScoreThreshold,
        dominanceGap: FingerprintConstants.driftScoreDominanceGap,
        maxResults: 2,
        rival: .runnerUp
    )

    /// The Auris endpoint's rule (cloud-ingestion.md): 0.65 floor, a 0.05 lead over
    /// the best candidate further than 2s away, ranking the matcher's top 6.
    /// Floor and anchor threshold are both 0.65 on purpose, and the overlay's missing
    /// "fired but untrusted" band is deliberate. Measured over 3,734 windows the lowest best
    /// score was 0.599, and unrelated audio scores 0.64–0.75, so a 0.5 visibility floor would
    /// filter nothing and would only add windows from audio that is not in the episode. What
    /// stays is the genuine near-miss signal: score >= 0.65 with no lead over a distant rival.
    static let auris = MatchAcceptanceRule(
        scoreThreshold: FingerprintConstants.aurisMatchScoreThreshold,
        anchorScoreThreshold: FingerprintConstants.aurisMatchScoreThreshold,
        dominanceGap: FingerprintConstants.aurisDominanceGap,
        maxResults: FingerprintConstants.aurisMaxResults,
        rival: .distant
    )
}
