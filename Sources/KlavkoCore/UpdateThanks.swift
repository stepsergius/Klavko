import Foundation

/// When to thank the user and ask for support: once, at the first launch of a newer version.
public enum UpdateThanks {
    /// `lastRunVersion`: the version Klavko last ran as (nil before 0.14, which started remembering it).
    /// `usedBefore`: Klavko had settings saved before this launch (so with no remembered version it's an
    /// update from an older one, not a first install). A reinstall of the same version or a downgrade: no.
    public static func shouldShow(lastRunVersion: String?, current: String, usedBefore: Bool) -> Bool {
        guard let last = lastRunVersion else { return usedBefore }
        return AppVersion.isNewer(current, than: last)
    }
}
