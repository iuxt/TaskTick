import XCTest
@testable import TaskTickApp

/// Covers the push-channel abstraction from issue #51. The Bark URL cases are
/// carried over verbatim from BarkPushManagerTests — the shapes users paste
/// didn't change when the provider list grew.
final class PushChannelTests: XCTestCase {

    // MARK: - Bark URL normalization

    func testEmptyAndWhitespaceRejected() {
        XCTAssertNil(BarkEndpoint.normalizedURL(from: ""))
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "   "))
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "\n\t"))
    }

    func testOfficialDeviceURLAccepted() {
        let url = BarkEndpoint.normalizedURL(from: "https://api.day.app/abcdefghijklmnop/")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/abcdefghijklmnop")
    }

    func testTrailingSlashAndWhitespaceStripped() {
        let url = BarkEndpoint.normalizedURL(from: "  https://api.day.app/deviceKey  ")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/deviceKey")
    }

    func testQueryItemsPreserved() {
        let url = BarkEndpoint.normalizedURL(from: "https://api.day.app/deviceKey/?sound=bell")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "api.day.app")
        XCTAssertEqual(url?.path, "/deviceKey")
        XCTAssertEqual(url?.query, "sound=bell")
    }

    func testBareDeviceKeyBecomesOfficialURL() {
        let url = BarkEndpoint.normalizedURL(from: "AbC_12-xy")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/AbC_12-xy")
    }

    func testSelfHostedURLAccepted() {
        let url = BarkEndpoint.normalizedURL(from: "https://bark.example.com/mykey/")
        XCTAssertEqual(url?.absoluteString, "https://bark.example.com/mykey")
    }

    func testHostOnlyOfficialURLRejected() {
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "https://api.day.app"))
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "https://api.day.app/"))
    }

    func testUnsupportedSchemeRejected() {
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "ftp://api.day.app/key"))
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "not a url"))
        XCTAssertNil(BarkEndpoint.normalizedURL(from: "key with spaces"))
    }

    // MARK: - Gotify endpoint

    func testGotifyAppendsMessagePath() {
        let url = GotifyEndpoint.messageURL(fromServer: "https://push.example.com")
        XCTAssertEqual(url?.absoluteString, "https://push.example.com/message")
    }

    func testGotifyBareHostGetsHTTPS() {
        let url = GotifyEndpoint.messageURL(fromServer: "push.example.com")
        XCTAssertEqual(url?.absoluteString, "https://push.example.com/message")
    }

    func testGotifyDoesNotDoubleMessagePath() {
        let url = GotifyEndpoint.messageURL(fromServer: "https://push.example.com/message/")
        XCTAssertEqual(url?.absoluteString, "https://push.example.com/message")
    }

    func testGotifySubPathDeploymentPreserved() {
        let url = GotifyEndpoint.messageURL(fromServer: "https://example.com/gotify/")
        XCTAssertEqual(url?.absoluteString, "https://example.com/gotify/message")
    }

    func testGotifyRejectsNonHTTPScheme() {
        XCTAssertNil(GotifyEndpoint.messageURL(fromServer: "ftp://push.example.com"))
        XCTAssertNil(GotifyEndpoint.messageURL(fromServer: ""))
    }

    func testGotifyRequiresToken() {
        var channel = PushChannel(kind: .gotify, serverURL: "https://push.example.com")
        XCTAssertEqual(channel.validationError, .missingToken)
        channel.token = "AbCdEf"
        XCTAssertNil(channel.validationError)
    }

    // MARK: - Webhook

    func testWebhookHeadersParsing() {
        XCTAssertEqual(WebhookEndpoint.parseHeaders(""), [:])
        XCTAssertEqual(WebhookEndpoint.parseHeaders("   "), [:])
        XCTAssertEqual(
            WebhookEndpoint.parseHeaders(#"{"Authorization": "Bearer x"}"#),
            ["Authorization": "Bearer x"]
        )
        // Numbers are rendered rather than rejected — hand-written JSON has them.
        XCTAssertEqual(WebhookEndpoint.parseHeaders(#"{"X-Retry": 3}"#), ["X-Retry": "3"])
        XCTAssertNil(WebhookEndpoint.parseHeaders("not json"))
        XCTAssertNil(WebhookEndpoint.parseHeaders(#"["array"]"#))
        XCTAssertNil(WebhookEndpoint.parseHeaders(#"{"nested": {"a": 1}}"#))
    }

    func testWebhookURLTemplateSubstitutesAndEncodes() {
        let url = WebhookEndpoint.requestURL(
            from: "https://ntfy.sh/topic?message={{body}}",
            title: "T",
            body: "a b&c"
        )
        // `&` must be encoded or it would inject a second query parameter.
        XCTAssertEqual(url?.absoluteString, "https://ntfy.sh/topic?message=a%20b%26c")
    }

    func testWebhookURLRejectsNonHTTP() {
        XCTAssertNil(WebhookEndpoint.requestURL(from: "ftp://example.com", title: "t", body: "b"))
        XCTAssertNil(WebhookEndpoint.requestURL(from: "{{body}}", title: "t", body: "b"))
    }

    /// The reason escaping isn't optional: raw script output routinely carries
    /// quotes and newlines, and pasting it into a JSON template unescaped
    /// produces a body the receiver rejects with a 400.
    func testWebhookJSONBodyStaysValidWithHostileOutput() {
        let hostile = "he said \"hi\"\nand\\or \t tabbed"
        let rendered = PushTemplate.render(
            #"{"text": "{{body}}"}"#,
            title: "T",
            body: hostile,
            escaping: .json
        )
        let data = Data(rendered.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        XCTAssertEqual(object?["text"], hostile)
    }

    func testWebhookRawEscapingLeavesValueAlone() {
        let rendered = PushTemplate.render("{{body}}", title: "T", body: "a\"b", escaping: .none)
        XCTAssertEqual(rendered, "a\"b")
    }

    func testUnknownPlaceholderLeftVerbatim() {
        let rendered = PushTemplate.render("{{nope}}-{{title}}", title: "T", body: "B", escaping: .none)
        XCTAssertEqual(rendered, "{{nope}}-T")
    }

    /// A value that itself looks like a placeholder must not be expanded again.
    func testSubstitutedValueIsNotReexpanded() {
        let rendered = PushTemplate.render("{{title}}", title: "{{body}}", body: "B", escaping: .none)
        XCTAssertEqual(rendered, "{{body}}")
    }

    func testEscapingPickedFromContentType() {
        XCTAssertEqual(PushTemplate.Escaping(forContentType: "application/json"), .json)
        XCTAssertEqual(PushTemplate.Escaping(forContentType: "APPLICATION/JSON; charset=utf-8"), .json)
        XCTAssertEqual(
            PushTemplate.Escaping(forContentType: "application/x-www-form-urlencoded"),
            .formURLEncoded
        )
        XCTAssertEqual(PushTemplate.Escaping(forContentType: "text/plain"), .none)
    }

    // MARK: - Request building

    func testGotifyRequestCarriesTokenHeaderAndJSONBody() throws {
        let channel = PushChannel(
            kind: .gotify,
            serverURL: "https://push.example.com",
            token: "AppToken123",
            priority: 7
        )
        guard case .success(let request) = PushRequestBuilder.makeRequest(
            for: channel, title: "Title", body: "Body"
        ) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.url?.absoluteString, "https://push.example.com/message")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gotify-Key"), "AppToken123")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["message"] as? String, "Body")
        XCTAssertEqual(json["title"] as? String, "Title")
        XCTAssertEqual(json["priority"] as? Int, 7)
    }

    func testGotifyPriorityClamped() throws {
        let channel = PushChannel(
            kind: .gotify, serverURL: "https://push.example.com", token: "t", priority: 99
        )
        guard case .success(let request) = PushRequestBuilder.makeRequest(
            for: channel, title: "t", body: "b"
        ) else {
            return XCTFail("expected a request")
        }
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(json["priority"] as? Int, 10)
    }

    func testWebhookGETCarriesNoBody() {
        let channel = PushChannel(
            kind: .webhook,
            serverURL: "https://example.com/hook?text={{body}}",
            httpMethod: "GET"
        )
        guard case .success(let request) = PushRequestBuilder.makeRequest(
            for: channel, title: "t", body: "b"
        ) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }

    func testWebhookCustomHeaderOverridesContentType() {
        let channel = PushChannel(
            kind: .webhook,
            serverURL: "https://example.com/hook",
            contentType: "application/json",
            headersJSON: #"{"Content-Type": "text/plain"}"#
        )
        guard case .success(let request) = PushRequestBuilder.makeRequest(
            for: channel, title: "t", body: "b"
        ) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    }

    func testInvalidChannelNeverProducesRequest() {
        let channel = PushChannel(kind: .bark, serverURL: "https://api.day.app")
        guard case .failure(let error) = PushRequestBuilder.makeRequest(
            for: channel, title: "t", body: "b"
        ) else {
            return XCTFail("expected failure for a host-only Bark URL")
        }
        XCTAssertEqual(error, .invalidURL)
    }

    // MARK: - Response interpretation

    func testBarkApplicationErrorInBodyBeatsHTTP200() {
        let data = Data(#"{"code":400,"message":"device key invalid"}"#.utf8)
        let error = PushRequestBuilder.interpret(kind: .bark, status: 200, data: data)
        XCTAssertEqual(error, .serverMessage("device key invalid"))
    }

    func testGotifyErrorBodyDecoded() {
        let data = Data(#"{"error":"Unauthorized","errorCode":401,"errorDescription":"bad token"}"#.utf8)
        let error = PushRequestBuilder.interpret(kind: .gotify, status: 401, data: data)
        XCTAssertEqual(error, .serverMessage("bad token"))
    }

    func testSuccessfulResponseInterpretsAsNil() {
        XCTAssertNil(PushRequestBuilder.interpret(kind: .gotify, status: 200, data: Data("{}".utf8)))
        XCTAssertNil(PushRequestBuilder.interpret(kind: .bark, status: 200, data: Data("{}".utf8)))
        XCTAssertNil(PushRequestBuilder.interpret(kind: .webhook, status: 204, data: Data()))
    }

    func testWebhookFallsBackToStatusCode() {
        XCTAssertEqual(
            PushRequestBuilder.interpret(kind: .webhook, status: 500, data: Data("nope".utf8)),
            .httpStatus(500)
        )
    }

    // MARK: - Channel resolution

    private func makeChannels() -> [PushChannel] {
        [
            PushChannel(kind: .bark, name: "A", serverURL: "https://api.day.app/keyA"),
            PushChannel(kind: .gotify, name: "B", serverURL: "https://push.example.com", token: "t"),
            PushChannel(kind: .bark, name: "Off", isEnabled: false, serverURL: "https://api.day.app/keyC"),
            PushChannel(kind: .bark, name: "Broken", serverURL: "https://api.day.app")
        ]
    }

    func testResolveNilMeansEveryReadyChannel() {
        let resolved = PushChannelStore.resolve(ids: nil, in: makeChannels())
        XCTAssertEqual(resolved.map(\.name), ["A", "B"])
    }

    func testResolveEmptySelectionMeansNothing() {
        XCTAssertTrue(PushChannelStore.resolve(ids: [], in: makeChannels()).isEmpty)
    }

    func testResolveKeepsStoreOrderNotSelectionOrder() {
        let channels = makeChannels()
        let ids = [channels[1].id, channels[0].id]
        XCTAssertEqual(PushChannelStore.resolve(ids: ids, in: channels).map(\.name), ["A", "B"])
    }

    func testResolveSkipsDisabledAndInvalidEvenWhenPinned() {
        let channels = makeChannels()
        let ids = [channels[2].id, channels[3].id]
        XCTAssertTrue(PushChannelStore.resolve(ids: ids, in: channels).isEmpty)
    }

    func testResolveIgnoresUnknownChannelIDs() {
        let channels = makeChannels()
        let ids = [channels[0].id, UUID()]
        XCTAssertEqual(PushChannelStore.resolve(ids: ids, in: channels).map(\.name), ["A"])
    }

    // MARK: - Persistence

    func testRoundTripThroughDefaults() {
        let suite = "test.push.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(PushChannelStore.load(defaults).isEmpty)
        XCTAssertFalse(PushChannelStore.hasAnyChannel(defaults))

        let channels = makeChannels()
        PushChannelStore.save(channels, to: defaults)
        XCTAssertEqual(PushChannelStore.load(defaults), channels)
        XCTAssertTrue(PushChannelStore.hasAnyChannel(defaults))
    }

    /// A config written by a build that didn't have every field yet must still
    /// load — throwing would wipe the user's whole channel list.
    func testDecodingToleratesMissingFields() throws {
        let json = Data(#"[{"kind":"gotify","serverURL":"https://push.example.com"}]"#.utf8)
        let channels = try JSONDecoder().decode([PushChannel].self, from: json)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].kind, .gotify)
        XCTAssertTrue(channels[0].isEnabled)
        XCTAssertEqual(channels[0].httpMethod, "POST")
        XCTAssertEqual(channels[0].priority, 5)
    }

    func testDisplayNameFallsBackToKindAndHost() {
        let channel = PushChannel(kind: .gotify, name: "  ", serverURL: "https://push.example.com")
        XCTAssertTrue(channel.displayName.contains("push.example.com"))

        let blank = PushChannel(kind: .webhook, name: "", serverURL: "")
        XCTAssertEqual(blank.displayName, PushProviderKind.webhook.displayName)
    }

    // MARK: - Output fingerprint

    func testOutputFingerprintIgnoresSurroundingWhitespace() {
        let a = PushDispatcher.outputFingerprint(stdout: "hello\n", stderr: "")
        let b = PushDispatcher.outputFingerprint(stdout: "  hello  ", stderr: "ignored")
        XCTAssertEqual(a, b)
    }

    func testOutputFingerprintChangesWhenStdoutChanges() {
        let a = PushDispatcher.outputFingerprint(stdout: "ok", stderr: "")
        let b = PushDispatcher.outputFingerprint(stdout: "changed", stderr: "")
        XCTAssertNotEqual(a, b)
    }

    func testOutputFingerprintFallsBackToStderrWhenStdoutEmpty() {
        let fromErr = PushDispatcher.outputFingerprint(stdout: "  \n", stderr: "boom")
        let sameErr = PushDispatcher.outputFingerprint(stdout: "", stderr: "boom")
        let fromOut = PushDispatcher.outputFingerprint(stdout: "boom", stderr: "")
        XCTAssertEqual(fromErr, sameErr)
        XCTAssertEqual(fromErr, fromOut)
    }

    func testShouldNotifyOnFirstRunAndOnChangeOnly() {
        let fp1 = PushDispatcher.outputFingerprint(stdout: "v1", stderr: "")
        let fp2 = PushDispatcher.outputFingerprint(stdout: "v2", stderr: "")
        XCTAssertTrue(PushDispatcher.shouldNotifyOnOutputChange(previousFingerprint: nil, currentFingerprint: fp1))
        XCTAssertFalse(PushDispatcher.shouldNotifyOnOutputChange(previousFingerprint: fp1, currentFingerprint: fp1))
        XCTAssertTrue(PushDispatcher.shouldNotifyOnOutputChange(previousFingerprint: fp1, currentFingerprint: fp2))
    }

    // MARK: - Misconfigured channels never hit the network

    func testEmptyURLPostFails() async {
        let result = await PushDispatcher.post(
            channel: PushChannel(kind: .bark, serverURL: ""),
            title: "t",
            body: "b"
        )
        guard case .failure(let error) = result else {
            return XCTFail("expected failure for empty URL")
        }
        XCTAssertEqual(error, .emptyURL)
    }

    func testInvalidURLPostFails() async {
        let result = await PushDispatcher.post(
            channel: PushChannel(kind: .bark, serverURL: "https://api.day.app"),
            title: "t",
            body: "b"
        )
        guard case .failure(let error) = result else {
            return XCTFail("expected failure for invalid URL")
        }
        XCTAssertEqual(error, .invalidURL)
    }
}
