import Foundation

/// Bridges `EnvironmentValues.openWindow` (a SwiftUI scene-only API) into
/// non-View contexts like AppDelegate. Stashed by the main window's view on
/// appear, called by AppDelegate when the user wants the
/// main window surfaced from elsewhere.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private init() {}

    var openMain: (() -> Void)?
}
