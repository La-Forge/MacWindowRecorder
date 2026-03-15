import AVFoundation
import CoreMedia

/// Converts `AVAudioTime` values to `CMTime`, choosing the most precise
/// clock source available and falling back gracefully.
///
/// Extracted as a standalone type so it can be unit-tested without a
/// running `AVAudioEngine` or `SCStream`.
enum CMTimeConverter {

    /// - Parameters:
    ///   - audioTime: The timestamp received from an `AVAudioEngine` tap callback.
    ///   - sampleRate: The hardware sample rate, used when only sample time is valid.
    /// - Returns: A `CMTime` on the same wall clock as `SCStream` video frames.
    static func cmTime(from audioTime: AVAudioTime, sampleRate: Double) -> CMTime {
        // Prefer host time — it's the same mach_absolute_time wall clock that
        // SCStream uses, guaranteeing audio/video synchronisation.
        if audioTime.isHostTimeValid {
            return cmTimeFromHostTime(audioTime.hostTime)
        }

        // Fall back to sample-based time when host time is unavailable.
        if audioTime.isSampleTimeValid {
            return CMTime(
                value: CMTimeValue(audioTime.sampleTime),
                timescale: CMTimeScale(sampleRate)
            )
        }

        // Last resort: current media time (should never happen in practice).
        return CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000_000)
    }

    // MARK: - Internal helper (internal for testability)

    /// Converts a raw mach host time tick to a nanosecond-timescale `CMTime`.
    static func cmTimeFromHostTime(_ hostTime: UInt64) -> CMTime {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos = hostTime * UInt64(info.numer) / UInt64(info.denom)
        return CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000)
    }
}
