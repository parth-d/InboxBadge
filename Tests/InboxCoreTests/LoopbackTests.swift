import Foundation
import Testing
@testable import InboxCore

struct LoopbackTests {
    @Test func parsesCallbackQuery() {
        let p = LoopbackListener.parseCallback(requestLine: "GET /?code=4%2F0A&state=xyz HTTP/1.1")
        #expect(p == ["code": "4/0A", "state": "xyz"])
        #expect(LoopbackListener.parseCallback(requestLine: "GET /?error=access_denied HTTP/1.1") == ["error": "access_denied"])
    }

    @Test func ignoresUnrelatedRequests() {
        #expect(LoopbackListener.parseCallback(requestLine: "GET /favicon.ico HTTP/1.1") == nil)
        #expect(LoopbackListener.parseCallback(requestLine: "GET /?foo=bar HTTP/1.1") == nil)
        #expect(LoopbackListener.parseCallback(requestLine: "POST /?state=a HTTP/1.1") == nil)
        #expect(LoopbackListener.parseCallback(requestLine: "garbage") == nil)
    }

    @Test func deliversCallbackOverARealSocketOnce() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.cancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/?code=a%2Fb&state=s1")!
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as! HTTPURLResponse).statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("done"))
        #expect(try await listener.awaitCallback() == ["code": "a/b", "state": "s1"])
        let (_, second) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?code=z&state=s2")!)
        #expect((second as! HTTPURLResponse).statusCode == 409)
        #expect(try await listener.awaitCallback() == ["code": "a/b", "state": "s1"])
    }

    @Test func favicon404DoesNotConsumeTheCallback() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.cancel() }
        let (_, icon) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((icon as! HTTPURLResponse).statusCode == 404)
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?state=ok&code=c")!)
        #expect(try await listener.awaitCallback()["state"] == "ok")
    }

    @Test(.enabled(if: nonLoopbackIPv4() != nil))
    func listenerIsNotReachableOnNonLoopbackInterfaces() async throws {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.cancel() }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        let url = URL(string: "http://\(nonLoopbackIPv4()!):\(port)/?state=x")!
        await #expect(throws: URLError.self) { _ = try await session.data(from: url) }
    }

    @Test func cancelFailsAWaitingCaller() async throws {
        let listener = try LoopbackListener()
        _ = try await listener.start()
        let waiting = Task { try await listener.awaitCallback() }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        await #expect(throws: InboxError.cancelled) { _ = try await waiting.value }
    }

    private func tokenAndProfileTransport() -> StubTransport {
        StubTransport { r in
            if r.url!.host == "oauth2.googleapis.com" {
                return (jsonData(["access_token": "A", "refresh_token": "RT", "expires_in": 3600]), 200)
            }
            return (jsonData(["emailAddress": "me@x.com", "historyId": "1"]), 200)
        }
    }

    private func browser(code: String?, error: String? = nil, stateOverride: String? = nil) -> @Sendable (URL) -> Void {
        { authURL in
            let q = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = q.first { $0.name == "redirect_uri" }!.value!
            let state = stateOverride ?? q.first { $0.name == "state" }!.value!
            var tail = "?state=\(state)"
            if let code { tail += "&code=\(code)" }
            if let error { tail += "&error=\(error)" }
            Task { _ = try? await URLSession.shared.data(from: URL(string: redirect + "/" + tail)!) }
        }
    }

    @Test func signInBindsVerifierToChallengeAndReturnsAccount() async throws {
        let t = tokenAndProfileTransport()
        nonisolated(unsafe) var challenge = ""
        let opener = browser(code: "the-code")
        let account = try await SignIn.run(client: testClient, transport: t) { url in
            challenge = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "code_challenge" }!.value!
            opener(url)
        }
        #expect(account == StoredAccount(email: "me@x.com", client: testClient, refreshToken: "RT"))
        let body = t.bodies(host: "oauth2.googleapis.com")[0]
        let verifier = body.components(separatedBy: "&").first { $0.hasPrefix("code_verifier=") }!.dropFirst("code_verifier=".count)
        #expect(PKCE.challenge(for: String(verifier)) == challenge)
        #expect(body.contains("code=the-code"))
    }

    @Test func signInRejectsStateMismatch() async {
        await #expect(throws: InboxError.malformed("callback")) {
            _ = try await SignIn.run(client: testClient, transport: tokenAndProfileTransport(),
                                     openURL: browser(code: "c", stateOverride: "forged"))
        }
    }

    @Test func signInSurfacesAuthorizationError() async {
        await #expect(throws: InboxError.authorization("access_denied")) {
            _ = try await SignIn.run(client: testClient, transport: tokenAndProfileTransport(),
                                     openURL: browser(code: nil, error: "access_denied"))
        }
    }

    @Test func signInWithoutRefreshTokenFails() async {
        let t = StubTransport { _ in (jsonData(["access_token": "A", "expires_in": 3600]), 200) }
        await #expect(throws: InboxError.malformed("no refresh token")) {
            _ = try await SignIn.run(client: testClient, transport: t, openURL: browser(code: "c"))
        }
    }

    @Test func signInTimesOut() async {
        await #expect(throws: InboxError.cancelled) {
            _ = try await SignIn.run(client: testClient, transport: tokenAndProfileTransport(), timeout: 0.2) { _ in }
        }
    }
}

func nonLoopbackIPv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = entry.pointee
        guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (a.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}
