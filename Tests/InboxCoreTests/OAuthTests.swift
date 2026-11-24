import Foundation
import Testing
@testable import InboxCore

struct OAuthTests {
    private func query(_ url: URL) -> [String: String] {
        Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { a, _ in a })
    }

    @Test func authorizationURLCarriesPKCEScopeAndOffline() {
        let url = OAuth.authorizationURL(client: testClient, redirectURI: "http://127.0.0.1:5000", challenge: "CH",
                                         state: "ST", loginHint: "me@x.com")
        let q = query(url)
        #expect(url.host == "accounts.google.com")
        #expect(q["code_challenge"] == "CH")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["scope"] == "https://www.googleapis.com/auth/gmail.modify")
        #expect(q["redirect_uri"] == "http://127.0.0.1:5000")
        #expect(q["state"] == "ST")
        #expect(q["access_type"] == "offline")
        #expect(q["login_hint"] == "me@x.com")
        #expect(q["client_id"] == "cid")
    }

    @Test func authorizationURLOmitsHintWhenAbsent() {
        let url = OAuth.authorizationURL(client: testClient, redirectURI: "r", challenge: "c", state: "s", loginHint: nil)
        #expect(query(url)["login_hint"] == nil)
    }

    @Test func exchangeSendsVerifierAndParsesGrant() async throws {
        let t = StubTransport { _ in
            (jsonData(["access_token": "A", "refresh_token": "R", "expires_in": 1800]), 200)
        }
        let grant = try await OAuth.exchange(code: "the-code", verifier: "the-verifier", redirectURI: "http://127.0.0.1:1",
                                             client: testClient, transport: t)
        #expect(grant == TokenGrant(accessToken: "A", refreshToken: "R", expiresIn: 1800))
        let body = t.bodies(host: "oauth2.googleapis.com")[0]
        #expect(body.contains("code_verifier=the-verifier"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=the-code"))
        #expect(body.contains("client_secret=csecret"))
    }

    @Test func invalidGrantMeansReauth() async {
        let t = StubTransport { _ in (jsonData(["error": "invalid_grant"]), 400) }
        await #expect(throws: InboxError.reauthRequired) {
            _ = try await OAuth.refresh(refreshToken: "R", client: testClient, transport: t)
        }
    }

    @Test func otherTokenFailureIsHTTPError() async {
        let t = StubTransport { _ in (jsonData(["error": "server_error"]), 500) }
        await #expect(throws: InboxError.http(500)) {
            _ = try await OAuth.refresh(refreshToken: "R", client: testClient, transport: t)
        }
    }

    @Test func tokenProviderServesCachedTokenWithoutNetwork() async throws {
        let t = StubTransport { _ in (Data(), 500) }
        let p = TokenProvider(client: testClient, refreshToken: "R", transport: t,
                              initial: TokenGrant(accessToken: "A0", refreshToken: nil, expiresIn: 3600))
        #expect(try await p.accessToken() == "A0")
        #expect(t.requests.isEmpty)
    }

    @Test func tokenProviderRefreshesAfterExpiry() async throws {
        let clock = Clock()
        let t = StubTransport { _ in (jsonData(["access_token": "A1", "expires_in": 3600]), 200) }
        let p = TokenProvider(client: testClient, refreshToken: "R", transport: t,
                              initial: TokenGrant(accessToken: "A0", refreshToken: nil, expiresIn: 3600),
                              now: { clock.now })
        #expect(try await p.accessToken() == "A0")
        clock.advance(3600 - 30)
        #expect(try await p.accessToken() == "A1")
        #expect(t.requests.count == 1)
        #expect(try await p.accessToken() == "A1")
        #expect(t.requests.count == 1)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let t = StubTransport { _ in (jsonData(["access_token": "A1", "expires_in": 3600]), 200) }
        let p = TokenProvider(client: testClient, refreshToken: "R", transport: t)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await p.accessToken() } }
            var all: [String] = []
            for try await v in group { all.append(v) }
            return all
        }
        #expect(tokens.allSatisfy { $0 == "A1" })
        #expect(t.requests.count == 1)
    }

    @Test func invalidateForcesRefresh() async throws {
        let t = StubTransport { _ in (jsonData(["access_token": "A1", "expires_in": 3600]), 200) }
        let p = TokenProvider(client: testClient, refreshToken: "R", transport: t,
                              initial: TokenGrant(accessToken: "A0", refreshToken: nil, expiresIn: 3600))
        await p.invalidate()
        #expect(try await p.accessToken() == "A1")
    }

    @Test func rotatedRefreshTokenIsUsedNext() async throws {
        let clock = Clock()
        let t = StubTransport { _ in (jsonData(["access_token": "A", "refresh_token": "R2", "expires_in": 100]), 200) }
        let p = TokenProvider(client: testClient, refreshToken: "R1", transport: t, now: { clock.now })
        _ = try await p.accessToken()
        clock.advance(200)
        _ = try await p.accessToken()
        let bodies = t.bodies(host: "oauth2.googleapis.com")
        #expect(bodies[0].contains("refresh_token=R1"))
        #expect(bodies[1].contains("refresh_token=R2"))
    }

    @Test func revokePostsTheRefreshTokenToGoogle() async {
        let t = StubTransport { _ in (Data(), 200) }
        let p = TokenProvider(client: testClient, refreshToken: "the-refresh", transport: t,
                              initial: TokenGrant(accessToken: "A0", refreshToken: nil, expiresIn: 3600))
        #expect(await p.revoke())
        let r = t.requests[0]
        #expect(r.url == OAuth.revokeEndpoint)
        #expect(r.httpMethod == "POST")
        #expect(String(decoding: r.httpBody!, as: UTF8.self) == "token=the-refresh")
    }

    @Test func revokeReportsFailureWithoutThrowing() async {
        let rejected = StubTransport { _ in (Data(), 400) }
        #expect(!(await TokenProvider(client: testClient, refreshToken: "r", transport: rejected).revoke()))
        let offline = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        #expect(!(await TokenProvider(client: testClient, refreshToken: "r", transport: offline).revoke()))
    }
}
