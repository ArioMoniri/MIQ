import Foundation

/// Whether a file lives on a local disk or a network mount.
///
/// Uses `statfs(2)`'s `MNT_LOCAL` flag, which is reliable inside the sandboxed
/// Quick Look preview and thumbnail extensions — unlike `URLResourceValues`
/// `.volumeIsLocalKey`, which can return `nil` there (volume metadata is
/// restricted) and silently mislead a caller into the wrong path.
public enum VolumeLocation {
    /// `true` when `url` is on a local volume. Defaults to `true` on a failed
    /// probe so callers keep their local fast path rather than the network one.
    public static func isLocal(_ url: URL) -> Bool {
        var info = statfs()
        let ok = url.withUnsafeFileSystemRepresentation { pointer -> Bool in
            guard let pointer else { return false }
            return statfs(pointer, &info) == 0
        }
        guard ok else { return true }
        return (info.f_flags & UInt32(MNT_LOCAL)) != 0
    }

    /// `SF_DATALESS` from `<sys/stat.h>`: the file's contents are not on disk
    /// (an iCloud Drive / File Provider placeholder, "Optimize Mac Storage").
    #if canImport(Darwin)
    static let dataLessFlag = UInt32(SF_DATALESS)
    #else
    /// Linux has no `st_flags` / `SF_DATALESS`; the value (Darwin's, 0x40000000)
    /// exists only so the Linux CI harness (`scripts/ci/linux_core_tests.sh`)
    /// compiles and can pin the constant. `isDataless` is always `false` there.
    static let dataLessFlag: UInt32 = 0x4000_0000
    #endif

    /// `true` when `url` is a dataless cloud placeholder: reading it would make
    /// the File Provider download the whole file first, which from Quick Look
    /// behaves like a slow network read (or blocks indefinitely offline).
    /// Callers route it like a network file: the preview defers it behind the
    /// "Load preview" placeholder and the thumbnail extension declines it.
    ///
    /// `stat(2)` only reads metadata, so the probe itself never triggers the
    /// download. `false` on a failed probe and on non-Darwin platforms (no
    /// `st_flags`), keeping the normal path.
    public static func isDataless(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { pointer -> Bool in
            guard let pointer else { return false }
            return stat(pointer, &info) == 0
        }
        guard ok else { return false }
        return (info.st_flags & dataLessFlag) != 0
        #else
        return false
        #endif
    }
}
