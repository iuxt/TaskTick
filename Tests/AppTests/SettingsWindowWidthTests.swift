import Testing
import AppKit
import Foundation
@testable import TaskTickApp

/// The settings tab bar silently collapses into a "»" overflow menu when its
/// items don't fit the window — no crash, no warning, the tabs are just gone.
/// It shipped that way in Russian and Spanish for a while because the width was
/// a single number measured in English.
///
/// These tests read every language's real tab titles off disk and check the
/// computed width against them, so a long translation or a newly added tab
/// fails here instead of in a user's screenshot.
/// `@MainActor` because `SettingsView` is a SwiftUI `View` and therefore
/// main-actor isolated — its statics included. Reaching them from a nonisolated
/// test traps at runtime rather than failing to compile (the package builds in
/// Swift 5 language mode, so the isolation violation is only checked
/// dynamically).
@Suite("Settings window width")
@MainActor
struct SettingsWindowWidthTests {

    private var localizationDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TaskTickCore/Localization")
    }

    /// (language, titles) for every shipped `.lproj`, in tab-bar order.
    private func titlesPerLanguage() throws -> [(String, [String])] {
        let lprojs = try FileManager.default
            .contentsOfDirectory(at: localizationDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try lprojs.map { lproj in
            let file = lproj.appendingPathComponent("Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: file) as? [String: String],
                                     "\(lproj.lastPathComponent) 解析失败")
            let titles = try SettingsView.Tab.allCases.map { tab in
                try #require(table[tab.rawValue],
                             "\(lproj.lastPathComponent) 缺少 tab 文案 \(tab.rawValue)")
            }
            return (lproj.deletingPathExtension().lastPathComponent, titles)
        }
    }

    @Test("每种语言的所有 tab 标题都存在（缺失会让宽度按 key 本身计算）")
    func everyLanguageHasEveryTabTitle() throws {
        let all = try titlesPerLanguage()
        #expect(!all.isEmpty, "未找到任何 .lproj，路径推导可能失效")
        for (lang, titles) in all {
            #expect(titles.count == SettingsView.Tab.allCases.count, "\(lang) tab 文案数量不符")
            #expect(titles.allSatisfy { !$0.isEmpty }, "\(lang) 有空的 tab 文案")
        }
    }

    @Test("每种语言算出的窗口宽度都装得下自己的 tab 栏")
    func widthFitsEveryLanguage() throws {
        // A wide screen so the display clamp never masks a too-narrow result.
        let screen: CGFloat = 3000
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        for (lang, titles) in try titlesPerLanguage() {
            let bar = titles.reduce(CGFloat.zero) { total, title in
                total + ceil((title as NSString).size(withAttributes: [.font: font]).width)
                    + SettingsView.itemPadding
            }
            let width = SettingsView.windowWidth(titles: titles, screenWidth: screen)
            #expect(width >= bar + 2 * SettingsView.barInset,
                    "\(lang): 窗口 \(width)pt 装不下 \(bar)pt 的 tab 栏，会折成 »")
        }
    }

    @Test("装得下的语言保持 680pt 原有比例")
    func shortLanguagesKeepTheFamiliarWidth() throws {
        let byLang = Dictionary(uniqueKeysWithValues: try titlesPerLanguage())
        for lang in ["zh-Hans", "zh-Hant", "ja", "ko", "en", "de", "es", "ru"] {
            let titles = try #require(byLang[lang])
            #expect(SettingsView.windowWidth(titles: titles, screenWidth: 3000) == 680,
                    "\(lang) 本来就装得下，不该被撑宽")
        }
    }

    @Test("长标题只加必要的宽度，不会变成怪物窗口")
    func longTitlesGrowButStayReasonable() {
        // The reduced tab set now fits Russian at 680pt too. Keep an explicit
        // long-label fixture to exercise expansion independently of translations.
        let titles = Array(repeating: String(repeating: "W", count: 12), count: 6)
        let width = SettingsView.windowWidth(titles: titles, screenWidth: 3000)
        #expect(width > 680, "长标题在 680pt 下会溢出，应该被撑宽")
        #expect(width <= 900, "窗口不应过度加宽")
    }

    /// The clamp that keeps a pathological translation from opening a window
    /// wider than the display — "»" is the lesser evil at that point.
    @Test("窄屏下不会开出比屏幕还宽的窗口")
    func neverExceedsTheScreen() throws {
        let monster = Array(repeating: String(repeating: "W", count: 40), count: SettingsView.Tab.allCases.count)
        let width = SettingsView.windowWidth(titles: monster, screenWidth: 1000)
        #expect(width == 920)
    }

    @Test("屏幕比 680 还窄时仍不塌到 680 以下")
    func neverShrinksBelowTheBaseline() {
        #expect(SettingsView.windowWidth(titles: ["A", "B"], screenWidth: 400) == 680)
    }
}
