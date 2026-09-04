import Testing
import Foundation
import SwiftData
import TaskTickCore
@testable import TaskTickApp

/// Covers the one-shot fold of the pre-#51 `barkServerURL` setting into a real
/// push channel. This is the only part of issue #51 that touches existing user
/// data, so the failure modes it guards against — a resurrected channel, a
/// duplicated one, or a task quietly losing its endpoint — are all silent ones.
@Suite("Push channel legacy migration")
@MainActor
struct PushChannelMigrationTests {

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let cfg = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        return (container, container.mainContext)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test.push.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("旧 Bark 地址迁移成一条渠道，并把已开启的任务钉在它上面")
    func migratesURLAndPinsTasks() throws {
        let (container, ctx) = try makeContext()
        _ = container
        let defaults = makeDefaults()
        defaults.set("https://api.day.app/legacyKey", forKey: PushChannelStore.legacyBarkURLKey)

        let on = ScheduledTask(name: "on")
        on.barkPushEnabled = true
        let off = ScheduledTask(name: "off")
        ctx.insert(on)
        ctx.insert(off)

        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)

        let channels = PushChannelStore.load(defaults)
        #expect(channels.count == 1)
        #expect(channels[0].kind == .bark)
        #expect(channels[0].serverURL == "https://api.day.app/legacyKey")

        // Pinned, not left on the nil sentinel: otherwise adding a Gotify
        // channel later would silently make this task double-push.
        #expect(on.pushChannelIDs == [channels[0].id])
        #expect(off.pushChannelIDs == nil)
    }

    @Test("迁移后的任务解析到那条渠道")
    func migratedTaskResolvesToChannel() throws {
        let (container, ctx) = try makeContext()
        _ = container
        let defaults = makeDefaults()
        defaults.set("legacyKey", forKey: PushChannelStore.legacyBarkURLKey)

        let task = ScheduledTask(name: "t")
        task.barkPushEnabled = true
        ctx.insert(task)

        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)

        let resolved = PushChannelStore.resolve(ids: task.pushChannelIDs, in: PushChannelStore.load(defaults))
        #expect(resolved.count == 1)
        #expect(resolved[0].serverURL == "legacyKey")
    }

    @Test("没有旧地址时什么都不建，但迁移标记照样落下")
    func noLegacyURLCreatesNothing() throws {
        let (container, ctx) = try makeContext()
        _ = container
        let defaults = makeDefaults()

        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)

        #expect(PushChannelStore.load(defaults).isEmpty)
        #expect(defaults.bool(forKey: PushChannelStore.migrationFlagKey))
    }

    @Test("无效的旧地址不会造出一条坏渠道")
    func invalidLegacyURLIgnored() throws {
        let (container, ctx) = try makeContext()
        _ = container
        let defaults = makeDefaults()
        defaults.set("https://api.day.app", forKey: PushChannelStore.legacyBarkURLKey)

        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)
        #expect(PushChannelStore.load(defaults).isEmpty)
    }

    @Test("重复运行不会产生第二条同地址渠道")
    func rerunDoesNotDuplicate() throws {
        let (container, ctx) = try makeContext()
        _ = container
        let defaults = makeDefaults()
        defaults.set("legacyKey", forKey: PushChannelStore.legacyBarkURLKey)

        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)
        defaults.set(false, forKey: PushChannelStore.migrationFlagKey)
        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)

        #expect(PushChannelStore.load(defaults).count == 1)
    }

    @Test("已手动选过渠道的任务不会被迁移覆盖")
    func existingSelectionNotOverwritten() throws {
        let (container, ctx) = try makeContext()
        _ = container
        let defaults = makeDefaults()
        defaults.set("legacyKey", forKey: PushChannelStore.legacyBarkURLKey)

        let chosen = UUID()
        let task = ScheduledTask(name: "t")
        task.barkPushEnabled = true
        task.pushChannelIDs = [chosen]
        ctx.insert(task)

        PushChannelStore.migrateLegacyBarkIfNeeded(context: ctx, defaults: defaults)
        #expect(task.pushChannelIDs == [chosen])
    }

    @Test("pushChannelIDs 的 JSON 往返：nil / 空数组 / 具体选择互不混淆")
    func channelIDCodingRoundTrip() {
        let task = ScheduledTask(name: "t")
        #expect(task.pushChannelIDs == nil)

        // Empty is a real selection ("push nowhere"), not the nil sentinel.
        task.pushChannelIDs = []
        #expect(task.pushChannelIDsJSON == "[]")
        #expect(task.pushChannelIDs == [])

        let ids = [UUID(), UUID()]
        task.pushChannelIDs = ids
        #expect(task.pushChannelIDs == ids)

        task.pushChannelIDs = nil
        #expect(task.pushChannelIDsJSON == nil)

        // A corrupt entry drops out instead of silencing the whole selection.
        task.pushChannelIDsJSON = #"["not-a-uuid","\#(ids[0].uuidString)"]"#
        #expect(task.pushChannelIDs == [ids[0]])
    }

    @Test("provider-neutral 别名与 legacy 字段是同一份存储")
    func aliasesShareStorage() {
        let task = ScheduledTask(name: "t")
        task.pushEnabled = true
        #expect(task.barkPushEnabled)
        task.barkNotifyOnOutputChange = true
        #expect(task.pushOnlyWhenOutputChanged)
        task.lastPushOutputFingerprint = "abc"
        #expect(task.lastBarkOutputFingerprint == "abc")
    }
}
