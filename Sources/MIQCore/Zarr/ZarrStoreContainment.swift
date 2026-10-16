import Foundation

/// Which files a Zarr preview may read: those inside the store the user
/// picked, plus git-annex content that the store's own symlinks point at.
///
/// DataLad / git-annex datasets keep every large file as a symlink into the
/// enclosing repository's object store, e.g.
/// `ds/sub.zarr/0/0.0.0 → ../../.git/annex/objects/Xk/Pq/SHA256E-…/SHA256E-…`
/// (or `ds/.git/modules/<sub>/annex/objects/…` for a submodule dataset). The
/// strict `MIQParser.containedResolvedURL` rule rejects those targets, so an
/// annexed store rendered as nothing but fill value.
enum ZarrStoreContainment {
    /// `url` with symlinks resolved, or nil unless it is safe to read:
    ///
    /// 1. **Lexically** (before any symlink is followed), `url` after `.`/`..`
    ///    normalisation lies strictly inside `storeRoot` — so a path built from
    ///    metadata can't climb out with `..` or name an absolute file.
    /// 2. The **resolved** target lies strictly inside the resolved store, or
    ///    inside an `annex/objects` directory of a `.git` directory that sits in
    ///    an ancestor of the store (the dataset that contains it).
    static func resolvedChunkURL(_ url: URL, storeRoot: URL) -> URL? {
        let lexical = url.standardizedFileURL.pathComponents
        guard !lexical.contains("..") else { return nil }
        let storeLexical = storeRoot.standardizedFileURL.pathComponents
        let storeResolved = storeRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        // `url` may be built on either spelling of the store (callers often hold
        // an already-resolved level directory, e.g. `/private/var/…` on macOS).
        guard Self.isStrictlyInside(lexical, storeLexical) || Self.isStrictlyInside(lexical, storeResolved) else {
            return nil
        }

        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = resolvedURL.pathComponents
        guard !resolved.contains("..") else { return nil }
        if Self.isStrictlyInside(resolved, storeResolved) { return resolvedURL }
        return Self.isInsideEnclosingAnnex(resolved, storeComponents: storeResolved) ? resolvedURL : nil
    }

    /// Whether `path` has more components than `directory` and starts with all of them.
    private static func isStrictlyInside(_ path: [String], _ directory: [String]) -> Bool {
        path.count > directory.count && Array(path.prefix(directory.count)) == directory
    }

    /// `path` is `<A>/.git/[modules/<name>/…]annex/objects/<…>` where `<A>` is the
    /// store directory or one of its ancestors (never the filesystem root alone).
    private static func isInsideEnclosingAnnex(_ path: [String], storeComponents: [String]) -> Bool {
        for gitIndex in path.indices where path[gitIndex] == ".git" {
            // `<A>` must be a real ancestor directory, not just "/".
            guard gitIndex >= 2, gitIndex <= storeComponents.count,
                  Array(path[..<gitIndex]) == Array(storeComponents.prefix(gitIndex)) else { continue }
            let rest = path[(gitIndex + 1)...]
            // `annex/objects` followed by at least one more component (the object).
            var index = rest.startIndex
            while index + 2 < rest.endIndex {
                if rest[index] == "annex", rest[index + 1] == "objects" { return true }
                index += 1
            }
        }
        return false
    }
}
