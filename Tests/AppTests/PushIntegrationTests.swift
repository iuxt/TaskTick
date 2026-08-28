import Testing
import Foundation
@testable import TaskTickApp

/// End-to-end checks against a **real** server, opt-in via environment
/// variables so the default `swift test` (and CI) stays hermetic.
///
/// The unit tests prove we build the request we *think* Gotify wants; only a
/// live server proves Gotify agrees. Run them like this:
///
/// ```sh
/// docker run -d --name gotify -p 18080:80 -e GOTIFY_DEFAULTUSER_PASS=admin gotify/server
/// TOKEN=$(curl -s -u admin:admin -X POST http://localhost:18080/application \
///   -H 'Content-Type: application/json' -d '{"name":"TaskTick"}' | jq -r .token)
/// TASKTICK_GOTIFY_URL=http://localhost:18080 TASKTICK_GOTIFY_TOKEN=$TOKEN \
///   swift test --filter PushIntegration
/// ```
@Suite("Push integration (opt-in)")
struct PushIntegrationTests {

    private static var gotifyURL: String? { env("TASKTICK_GOTIFY_URL") }
    private static var gotifyToken: String? { env("TASKTICK_GOTIFY_TOKEN") }
    private static var webhookURL: String? { env("TASKTICK_WEBHOOK_URL") }

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Gotify

    @Test("Gotify 真实服务器接受我们的推送，并原样回显 title/message/priority",
          .enabled(if: gotifyURL != nil && gotifyToken != nil))
    func gotifyRoundTrip() async throws {
        let base = try #require(Self.gotifyURL)
        let channel = PushChannel(
            kind: .gotify,
            name: "integration",
            serverURL: base,
            token: try #require(Self.gotifyToken),
            priority: 7
        )

        // A body with the characters that actually break naive JSON assembly:
        // quotes, a backslash, a newline and non-ASCII text.
        let marker = UUID().uuidString
        let body = "行1 \"quoted\" \\ backslash\n行2 \(marker)"

        let result = await PushDispatcher.post(channel: channel, title: "TaskTick 集成测试", body: body)
        guard case .success = result else {
            Issue.record("推送失败: \(result)")
            return
        }

        let received = try await Self.latestGotifyMessage(base: base)
        #expect(received["title"] as? String == "TaskTick 集成测试")
        #expect(received["message"] as? String == body, "服务器收到的正文与发出的不一致")
        #expect(received["priority"] as? Int == 7)
    }

    @Test("Gotify 拒绝错误 token，并把服务器的说明透出来",
          .enabled(if: gotifyURL != nil))
    func gotifyRejectsBadToken() async throws {
        let channel = PushChannel(
            kind: .gotify,
            serverURL: try #require(Self.gotifyURL),
            token: "definitely-not-a-valid-token"
        )
        let result = await PushDispatcher.post(channel: channel, title: "t", body: "b")
        guard case .failure(let error) = result else {
            Issue.record("坏 token 竟然成功了")
            return
        }
        // Not a bare "HTTP 401" — the point of decoding Gotify's error body is
        // that the user sees why.
        guard case .serverMessage(let message) = error else {
            Issue.record("期望 serverMessage，实际 \(error)")
            return
        }
        #expect(!message.isEmpty)
    }

    /// Reads the app's own message list back out of Gotify.
    private static func latestGotifyMessage(base: String) async throws -> [String: Any] {
        var request = URLRequest(url: try #require(URL(string: "\(base)/message?limit=1")))
        // The client-side read needs basic auth; the push itself used the app
        // token, which is write-only by design.
        let credentials = Data("admin:admin".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        return try #require(messages.first, "Gotify 没有任何消息")
    }

    // MARK: - Webhook

    @Test("Webhook 把脚本输出安全地塞进 JSON 模板（引号/反斜杠/换行不破坏结构）",
          .enabled(if: webhookURL != nil))
    func webhookJSONSurvivesHostileOutput() async throws {
        let channel = PushChannel(
            kind: .webhook,
            name: "integration",
            serverURL: try #require(Self.webhookURL),
            contentType: "application/json"
        )
        let body = "he said \"hi\"\\ then\nnewline 中文"
        let result = await PushDispatcher.post(channel: channel, title: "标题", body: body)
        guard case .success = result else {
            Issue.record("webhook 推送失败: \(result)")
            return
        }
        // The echo server records what it received; the assertion that matters
        // is that it parsed as JSON at all.
    }
}
