import Foundation

/// Identifies the running app variant so development and release data stay separate.
public enum BundleContext {
    public static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.lifedever.TaskTick"
    }

    public static var isDev: Bool {
        bundleID.hasSuffix(".dev")
    }
}
