import Foundation

public struct TokenGrant: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

public enum OAuth {
    public static let scope = "https://www.googleapis.com/auth/gmail.modify"
    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    public static func authorizationURL(client: OAuthClient, redirectURI: String, challenge: String,
                                        state: String, loginHint: String?) -> URL {
        var query: [(String, String)] = [
            ("client_id", client.clientID),
            ("redirect_uri", redirectURI),
            ("response_type", "code"),
            ("scope", scope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        if let loginHint { query.append(("login_hint", loginHint)) }
        return URL(string: authEndpoint + "?" + FormEncoding.encode(query))!
    }

    public static func exchange(code: String, verifier: String, redirectURI: String, client: OAuthClient,
                                transport: HTTPTransport) async throws -> TokenGrant {
        try await tokenRequest([
            ("client_id", client.clientID), ("client_secret", client.clientSecret),
            ("code", code), ("code_verifier", verifier),
            ("grant_type", "authorization_code"), ("redirect_uri", redirectURI),
        ], transport)
    }

    public static func refresh(refreshToken: String, client: OAuthClient,
                               transport: HTTPTransport) async throws -> TokenGrant {
        try await tokenRequest([
            ("client_id", client.clientID), ("client_secret", client.clientSecret),
            ("refresh_token", refreshToken), ("grant_type", "refresh_token"),
        ], transport)
    }

    private static func tokenRequest(_ fields: [(String, String)], _ transport: HTTPTransport) async throws -> TokenGrant {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(fields).utf8)
        let (data, status) = try await transport.send(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 200, let access = object["access_token"] as? String {
            return TokenGrant(accessToken: access,
                              refreshToken: object["refresh_token"] as? String,
                              expiresIn: (object["expires_in"] as? Double) ?? 3600)
        }
        if (object["error"] as? String) == "invalid_grant" { throw InboxError.reauthRequired }
        throw InboxError.http(status)
    }
}

public actor TokenProvider {
    private let client: OAuthClient
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var refreshToken: String
    private var access: (value: String, expires: Date)?
    private var inflight: Task<TokenGrant, Error>?

    public init(client: OAuthClient, refreshToken: String, transport: HTTPTransport,
                initial: TokenGrant? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.refreshToken = refreshToken
        self.transport = transport
        self.now = now
        if let initial { access = (initial.accessToken, now().addingTimeInterval(initial.expiresIn)) }
    }

    public func accessToken() async throws -> String {
        if let access, access.expires > now().addingTimeInterval(60) { return access.value }
        if let inflight { return try await inflight.value.accessToken }
        let client = self.client, token = self.refreshToken, transport = self.transport
        let task = Task { try await OAuth.refresh(refreshToken: token, client: client, transport: transport) }
        inflight = task
        defer { inflight = nil }
        let grant = try await task.value
        access = (grant.accessToken, now().addingTimeInterval(grant.expiresIn))
        if let rotated = grant.refreshToken { refreshToken = rotated }
        return grant.accessToken
    }

    public func invalidate() { access = nil }
}
