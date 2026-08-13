//
//  RetryPolicy.swift
//
//  Transport-error retry classification and jittered exponential backoff,
//  ported from Grok Build's `xai-grok-sampler/src/retry.rs`.
//
//  LAYER-3 CONCERN (the actor): the retry loop in
//  `OpenAICompatibleClient.streamChatCompletion` consults this to decide
//  whether a failed attempt deserves another try, and for how long to
//  sleep before the next attempt. The classifier is pure; no I/O.
//
//  RETRY BEHAVIOR (matches Grok Build):
//    Retried (up to maxRetries, ~6 min with 30s backoff cap):
//      - 500, 502, 503, 504, 520 (server errors)
//      - Connection errors (timeout, refused, reset) via BackendError.transport
//      - Mid-stream failures (SSE parse error after headers)
//    Retried with lower cap (rateLimitThreshold = 2):
//      - 429 (rate limited) — avoids burning long waits
//    Not retried (fatal immediately):
//      - 400, 401, 403, 404, 408, 422 (client errors)
//      - Cancelled
//
//  BACKOFF:
//    jitteredBackoff(n) = clamp(2s * 2^n, 0, 30s) ± 20% jitter
//    doomLoopBackoff(n) = random in [0, 250ms] — near-immediate resample
//

import Foundation

// MARK: - Retry classification

/// Outcome of classifying a failed attempt. Pure value; the actor
/// interprets it (retry, escalate, or give up).
public enum RetryOutcome: Sendable {
    /// The error is retryable. Sleep for `delay` before the next attempt.
    case retry(delay: TimeInterval)
    /// The error is retryable but we've exhausted the budget for this
    /// category (e.g. 429 rate-limit retries capped at 2). Escalate now.
    case escalate(reason: String)
    /// The error is not retryable. Fail immediately with `reason`.
    case fatal(reason: String)
}

/// Pure classifier for transport errors. Mirrors Grok Build's
/// `SamplingError::is_retryable()` + `RetryPolicy` logic without taking
/// any I/O dependencies — the actor calls this after catching an error.
public enum RetryClassifier {

    /// Classify a `BackendError` from a failed streaming attempt, given
    /// the current retry count and policy thresholds.
    ///
    /// - Parameters:
    ///   - error: The error from the failed attempt.
    ///   - attemptCount: How many retries have already happened (0 = first failure).
    ///   - maxRetries: Absolute ceiling on retries (default 15, ~6 min budget).
    ///   - rateLimitThreshold: After this many 429s, escalate instead of
    ///     waiting again (default 2 — rate-limit waits can be very long).
    public static func classify(
        _ error: BackendError,
        attemptCount: Int,
        maxRetries: Int = RetryPolicy.defaultMaxRetries,
        rateLimitThreshold: Int = RetryPolicy.rateLimitRetryThreshold
    ) -> RetryOutcome {
        // Exhausted budget → escalate (we've retried enough; surface the error).
        if attemptCount >= maxRetries {
            return .escalate(reason: "Exhausted \(maxRetries) retries: \(error.errorDescription ?? "")")
        }

        switch error {
        case .cancelled:
            // Cancellation is intentional — never retry.
            return .fatal(reason: "Cancelled")

        case .http(let status, let body):
            // 429 rate-limited: retryable but with a lower cap to avoid
            // burning long backoffs just to be rate-limited again.
            if status == 429 {
                if attemptCount >= rateLimitThreshold {
                    return .escalate(reason: "Rate-limited \(attemptCount)× — escalating to avoid long waits")
                }
                return .retry(delay: RetryPolicy.jitteredBackoff(attempt: attemptCount))
            }

            // 5xx server errors (including 520 CloudFlare) are retryable.
            if isRetryableStatus(status) {
                return .retry(delay: RetryPolicy.jitteredBackoff(attempt: attemptCount))
            }

            // 4xx client errors (except 429) are fatal — retrying won't help.
            return .fatal(reason: "HTTP \(status): \(body.prefix(200))")

        case .transport(let message):
            // Hard connect failures (server not running) used to burn the full
            // ~15-retry / ~6 min budget — terrible UX when LM Studio/Ollama is
            // simply off. Fail after a short retry budget; flaky mid-session
            // resets still get a couple of chances.
            if isHardConnectFailure(message) {
                if attemptCount >= RetryPolicy.hardConnectRetryThreshold {
                    return .escalate(reason: "Server unreachable after \(attemptCount + 1) attempts: \(message.prefix(200))")
                }
                return .retry(delay: RetryPolicy.jitteredBackoff(attempt: attemptCount))
            }
            // Other transport errors (timeout, reset mid-stream) keep the
            // full maxRetries budget.
            return .retry(delay: RetryPolicy.jitteredBackoff(attempt: attemptCount))

        case .decoding:
            // Parse failures mid-stream. Grok retries these (a flaky server
            // can emit a bad chunk once); we do too, but with a lower cap so
            // a persistently-broken stream fails in seconds not minutes.
            if attemptCount >= RetryPolicy.decodingRetryThreshold {
                return .escalate(reason: "SSE decode failed \(attemptCount + 1)× — escalating")
            }
            return .retry(delay: RetryPolicy.jitteredBackoff(attempt: attemptCount))

        case .unsupported:
            // Unsupported means the backend can't serve this request at all.
            return .fatal(reason: error.errorDescription ?? "Unsupported")
        }
    }

    /// HTTP status codes we retry. Everything else in 4xx is fatal.
    static func isRetryableStatus(_ status: Int) -> Bool {
        switch status {
        case 500, 502, 503, 504, 520: return true
        default: return false
        }
    }

    /// True when the transport error means "nothing is listening" rather
    /// than a flaky mid-stream glitch. Matched case-insensitively against
    /// common Foundation / URLSession phrasing.
    static func isHardConnectFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        let needles = [
            "connection refused",
            "could not connect",
            "couldn't connect",
            "failed to connect",
            "network is unreachable",
            "host is down",
            "no route to host",
            "socket is not connected",
            "not connected to host",
            "err_connection_refused",
            // Offline / DNS / cannot-connect. Match both URLError.localizedDescription
            // and the NSError fallback ("NSURLErrorDomain error -NNNN.").
            "the internet connection appears to be offline",
            "a server with the specified hostname could not be found",
            "hostname could not be found",
            "cannot find host",
            "could not find host",
            "cannot connect to host",
            "code=-1003",   // NSURLErrorCannotFindHost
            "code=-1004",   // NSURLErrorCannotConnectToHost
            "code=-1009",   // NSURLErrorNotConnectedToInternet
            "error -1003",
            "error -1004",
            "error -1009",
        ]
        return needles.contains { m.contains($0) }
    }
}

// MARK: - Backoff

/// Backoff calculation matching Grok Build's `retry_backoff_with_jitter`
/// and `doom_loop_backoff` from `retry.rs`.
///
/// **Standard retry**: 2s, 4s, 8s, 16s, then flat at ~30s, with ±20%
/// jitter to prevent thundering-herd retry storms when multiple clients
/// hit the same failing endpoint simultaneously.
///
/// **Doom-loop resample**: near-immediate (0–250ms) because loops are
/// stochastic at sampling temperature — a fresh sample is the remedy,
/// waiting buys nothing beyond de-syncing concurrent resamples.
public enum RetryPolicy {

    /// Default max retries (15). With 30s backoff cap this gives ~6 min
    /// of retry budget: retries 1-4 are exponential (2s+4s+8s+16s ≈ 30s),
    /// retries 5-15 are flat at ~30s each (≈5.5 min).
    public static let defaultMaxRetries: Int = 15

    /// After this many 429 rate-limit retries, escalate to the caller.
    /// Rate-limit waits can be long and there's no point burning a long
    /// backoff just to be rate-limited again.
    public static let rateLimitRetryThreshold: Int = 2

    /// Hard connect failures (connection refused / host down): stop after
    /// this many *retries* (attemptCount), i.e. 3 total attempts including
    /// the first. Keeps offline UX snappy when the local server is off.
    public static let hardConnectRetryThreshold: Int = 2

    /// Mid-stream SSE decode failures: escalate after this many retries.
    public static let decodingRetryThreshold: Int = 3

    /// Cap on backoff delay (30 seconds). Matches Grok Build's MAX_DELAY.
    public static let maxBackoffDelay: TimeInterval = 30.0

    /// Base delay for exponential backoff (2 seconds).
    public static let baseBackoffDelay: TimeInterval = 2.0

    /// Exponential backoff with ±20% jitter, capped at `maxBackoffDelay`.
    ///
    /// Formula: `clamp(base * 2^attempt, 0, max) ± 20%`
    ///
    /// For attempt N (0-indexed):
    ///   - Attempt 0: ~2s ± 0.4s
    ///   - Attempt 1: ~4s ± 0.8s
    ///   - Attempt 2: ~8s ± 1.6s
    ///   - Attempt 3: ~16s ± 3.2s
    ///   - Attempt 4+: ~30s ± 6s (capped)
    ///
    /// Jitter is seeded from the wall clock + attempt index so concurrent
    /// retries on different threads get distinct delays without lock
    /// contention. This prevents synchronized retry storms when N clients
    /// all back off the same amount after a server crash.
    public static func jitteredBackoff(attempt: Int) -> TimeInterval {
        let base = baseBackoffDelay * pow(2.0, Double(max(0, attempt)))
        let capped = min(base, maxBackoffDelay)

        // ±20% jitter: [capped - 10%, capped + 10%]
        let jitterRange = capped * 0.10
        let raw = jitterSeed(attempt)                 // [0, 1)
        let offset = (raw - 0.5) * 2 * jitterRange    // [-jitterRange, +jitterRange]
        return max(0, capped + offset)
    }

    /// Near-immediate backoff for doom-loop resamples (0–250ms).
    ///
    /// Loops are stochastic at sampling temperature, so a fresh sample is
    /// the remedy — waiting buys nothing beyond de-syncing concurrent
    /// resamples. The jitter prevents two parallel agents from resampling
    /// in lockstep.
    public static func doomLoopBackoff(attempt: Int) -> TimeInterval {
        let raw = jitterSeed(attempt + 0xFF)          // offset seed so it differs
        return raw * 0.250                             // [0, 250ms]
    }

    /// Jitter seed in [0, 1) for a given attempt index. Uses the wall
    /// clock (nanosecond resolution on Apple platforms) mixed with the
    /// attempt so concurrent calls produce distinct values without lock
    /// contention. The hash avalanche (fmix64 from MurmurHash3) ensures
    /// uniform distribution even when `attempt` values are close together.
    private static func jitterSeed(_ salt: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: salt)
        h ^= UInt64(Date().timeIntervalSinceReferenceDate * 1e9)   // wall-clock nanos
        h &*= 0x9E3779B97F4A7C15   // golden ratio (MurmurHash3 fmix64)
        h ^= h >> 33
        h &*= 0xFF51AFD7ED558CCD
        h ^= h >> 33
        return Double(h % (1 << 53)) / Double(1 << 53)
    }
}