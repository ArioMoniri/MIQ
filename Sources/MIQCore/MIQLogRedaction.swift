import Foundation

/// Helpers for keeping file names out of the unified log.
///
/// Medical file names routinely carry patient identifiers (`sub-<MRN>_T1w.nii.gz`,
/// `DOE_JOHN_19700101.mgz`), and anything logged with `privacy: .public` is readable
/// by any admin user via `log show` and lands in sysdiagnose archives. Log a
/// `fileTag` publicly instead: it is stable for one path, so the lines of one
/// preview can still be correlated, but it does not reveal the name.
public enum MIQLogRedaction {
    /// 8-hex-digit FNV-1a (32-bit) of the standardized file path.
    public static func fileTag(_ url: URL) -> String {
        fileTag(path: url.standardizedFileURL.path)
    }

    /// 8-hex-digit FNV-1a (32-bit) of `path`'s UTF-8 bytes.
    public static func fileTag(path: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }
}
