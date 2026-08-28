import Foundation
import SwiftData
import TaskTickCore

/// Persists the user's push channels and owns the one-way migration off the
/// single hard-coded Bark URL (issue #51).
///
/// Channels live in UserDefaults rather than SwiftData: they're app-wide
/// configuration, not user content, and keeping them out of the store means the
/// CLI's read-only container never has to know about them.
enum PushChannelStore {

    static let defaultsKey = "pushChannels"
    /// Pre-#51 single-endpoint setting. Read exactly once, by the migration
    /// below, then left alone forever — it stays on disk so a downgrade to an
    /// older TaskTick still finds its Bark URL.
    static let legacyBarkURLKey = "barkServerURL"
    static let migrationFlagKey = "pushChannelsMigratedFromBark"

    // MARK: - Persistence

    static func load(_ defaults: UserDefaults = .standard) -> [PushChannel] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PushChannel].self, from: data)) ?? []
    }

    static func save(_ channels: [PushChannel], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(channels) else {
            NSLog("⚠️ Push channels could not be encoded — settings left unchanged")
            return
        }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Any channel configured at all, enabled or not. Drives the "you haven't
    /// set up a channel yet" hint in the task editor.
    static func hasAnyChannel(_ defaults: UserDefaults = .standard) -> Bool {
        !load(defaults).isEmpty
    }

    // MARK: - Resolution

    /// The channels a task actually delivers to.
    ///
    /// `ids == nil` means "every enabled channel" — the behavior every task had
    /// when Bark was the only endpoint, and the default for a task the user
    /// hasn't narrowed down. A selection is otherwise honored literally,
    /// *including the empty one*: unchecking every box means "don't push", not
    /// "push everywhere". Likewise, pinning a channel that was later deleted
    /// delivers to what's left rather than quietly widening back out.
    ///
    /// Every call site goes through here — the selection rule is subtle enough
    /// that a second copy would drift.
    static func resolve(ids: [UUID]?, in channels: [PushChannel]) -> [PushChannel] {
        let ready = channels.filter(\.isReadyToSend)
        guard let ids else { return ready }
        let wanted = Set(ids)
        // Filter the store's array (not the id list) so the delivery order
        // matches the order shown in Settings.
        return ready.filter { wanted.contains($0.id) }
    }

    static func resolve(for task: ScheduledTask, defaults: UserDefaults = .standard) -> [PushChannel] {
        resolve(ids: task.pushChannelIDs, in: load(defaults))
    }

    // MARK: - Legacy migration

    /// Folds the old `barkServerURL` setting into a real channel, once.
    ///
    /// Also pins every task that already had Bark switched on to *that* channel
    /// specifically. Without the pin those tasks would sit on the `nil` =
    /// "all enabled channels" default, and the day the user adds a Gotify
    /// endpoint every one of them would silently start double-pushing.
    @MainActor
    static func migrateLegacyBarkIfNeeded(context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        // Marked done on every exit path: a user who never configured Bark has
        // nothing to migrate, and re-scanning each launch would resurrect a
        // channel they deleted.
        defer { defaults.set(true, forKey: migrationFlagKey) }

        let legacyURL = (defaults.string(forKey: legacyBarkURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyURL.isEmpty, BarkEndpoint.normalizedURL(from: legacyURL) != nil else { return }

        var channels = load(defaults)
        guard !channels.contains(where: { $0.kind == .bark && $0.serverURL == legacyURL }) else { return }

        let migrated = PushChannel(
            kind: .bark,
            name: PushProviderKind.bark.displayName,
            serverURL: legacyURL
        )
        channels.append(migrated)
        save(channels, to: defaults)

        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate<ScheduledTask> { $0.barkPushEnabled == true }
        )
        guard let tasks = try? context.fetch(descriptor) else { return }
        for task in tasks where task.pushChannelIDsJSON == nil {
            task.pushChannelIDs = [migrated.id]
        }
        do { try context.save() } catch { NSLog("⚠️ Push channel migration save failed: \(error)") }
    }
}
