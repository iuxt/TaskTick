import Foundation

/// Resolves the running TaskTick variant's bundle identifier.
///
/// `Bundle.main.bundleIdentifier` works for the GUI process and for CLI
/// binaries invoked by their direct .app/Contents/MacOS/ path. But when the
/// CLI is invoked via a symlink (e.g. `/opt/homebrew/bin/tasktick-dev` →
/// `/Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev`),
/// `Bundle.main.bundleIdentifier` returns nil — symlink resolution doesn't
/// kick in, and there's no Info.plist co-located with the .build/debug
/// binary or the symlink in /opt/homebrew/bin.
///
/// Without this fallback, the fallback default (release bundle ID) is used,
/// which causes the dev CLI to read the release SwiftData store and trip
/// the schema-migration / readonly error reported by users.
public enum BundleContext {

    /// Best-effort bundle identifier for the running TaskTick variant.
    /// Order of preference:
    /// 1. `Bundle.main.bundleIdentifier` (works for GUI + direct-path CLI)
    /// 2. Walk the resolved executable path up to find the nearest `.app`
    ///    ancestor and read its `Contents/Info.plist`'s `CFBundleIdentifier`
    /// 3. Fallback `"com.lifedever.TaskTick"` (release default — only hits
    ///    when the CLI is run from a build dir without an enclosing .app)
    public static var bundleID: String {
        if let id = Bundle.main.bundleIdentifier {
            return id
        }
        if let id = bundleIDFromEnclosingApp() {
            return id
        }
        return "com.lifedever.TaskTick"
    }

    /// True if the resolved bundle ID corresponds to the dev variant.
    public static var urlScheme: String { isDev ? "tasktick-dev" : "tasktick" }

    public static var isDev: Bool {
        bundleID.hasSuffix(".dev")
    }

    private static func bundleIDFromEnclosingApp() -> String? {
        guard let exec = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        var current = exec
        // Walk up the directory tree. The deepest plausible .app ancestor
        // for a CLI binary at `.app/Contents/MacOS/<bin>` is 3 levels up.
        // Cap iterations at the path's component count for safety.
        let maxDepth = current.pathComponents.count
        for _ in 0..<maxDepth {
            current.deleteLastPathComponent()
            if current.pathExtension == "app" {
                let plistURL = current.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(
                       from: data, options: [], format: nil) as? [String: Any],
                   let id = plist["CFBundleIdentifier"] as? String {
                    return id
                }
            }
        }
        return nil
    }
}
