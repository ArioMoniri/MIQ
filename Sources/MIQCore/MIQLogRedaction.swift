import Foundation

/// Helpers for keeping file names out of the unified log.
///
/// Medical file names routinely carry patient identifiers (`sub-<MRN>_T1w.nii.gz`,
/// `DOE_JOHN_19700101.mgz`), and anything logged with `privacy: .public` is readable
/// by any admin user via `log show` and lands in sysdiagnose archives. Log a
/// `fileTag` publicly instead: it is stable for one path, so the lines of one
/// preview can still be correlated, but it does not reveal the name.
///
/// The hash is keyed with a random per-install salt kept in the App Group store
/// (`MIQConfig.sharedStore`), shared by the app and its extensions so their tags
/// still match. Without the salt, anyone holding a log could confirm a guessed
/// path (`/Users/x/DOE_JOHN.nii.gz`) by hashing it. When no App Group is
/// configured (tests, the CLI, a misconfigured build) the tag falls back to the
/// unsalted, deterministic hash.
public enum MIQLogRedaction {
    /// App Group defaults key holding the per-install salt (16 random bytes, hex).
    static let saltKey = "logRedactionSalt"

    /// 8-hex-digit salted FNV-1a (32-bit) of the standardized file path.
    public static func fileTag(_ url: URL) -> String {
        fileTag(path: url.standardizedFileURL.path)
    }

    /// 8-hex-digit salted FNV-1a (32-bit) of `path`'s UTF-8 bytes.
    public static func fileTag(path: String) -> String {
        fileTag(path: path, salt: installSalt)
    }

    /// FNV-1a over `salt` then `path`. An empty salt is the plain hash of `path`.
    static func fileTag(path: String, salt: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in salt.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// Read (or created) once per process. A lazily initialised `static let` is
    /// thread-safe. Two processes racing on first launch may each write a salt;
    /// the last write wins and every later process reads that one.
    private static let installSalt: String = {
        guard !MIQConfig.appGroupID.isEmpty else { return "" }
        return salt(in: MIQConfig.sharedStore)
    }()

    /// The salt stored in `store`, creating and saving a random one if absent
    /// or malformed.
    static func salt(in store: UserDefaults) -> String {
        if let existing = store.string(forKey: saltKey), existing.count == 32,
           existing.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) {
            return existing
        }
        var generator = SystemRandomNumberGenerator()
        let fresh = (0..<16).map { _ -> String in
            let hex = String(UInt8.random(in: .min ... .max, using: &generator), radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
        store.set(fresh, forKey: saltKey)
        return fresh
    }
}
