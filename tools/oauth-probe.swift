// W0 probe: loopback + PKCE sign-in, prints INBOX threadsUnread, opens three candidate
// deep links for the newest inbox thread. Read-only calls. Tokens stay in memory and are
// never printed; the account address and thread id are written only to .probe-links (mode 600).
// Build: swiftc -swift-version 5 -O tools/oauth-probe.swift -o .build/oauth-probe
// Run:   .build/oauth-probe <client_secret.json> [login_hint]
import Foundation
import Network
import CryptoKit

func fail(_ m: String) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: oauth-probe <client_secret.json> [login_hint]") }
let hint = args.count > 2 ? args[2] : nil

struct ClientFile: Decodable {
    struct Installed: Decodable { let client_id: String; let client_secret: String }
    let installed: Installed
}
guard let raw = FileManager.default.contents(atPath: args[1]),
      let client = try? JSONDecoder().decode(ClientFile.self, from: raw).installed
else { fail("cannot read client json (expected an \"installed\" Desktop client)") }

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func randomString(_ n: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: n)
    guard SecRandomCopyBytes(kSecRandomDefault, n, &bytes) == errSecSuccess else { fail("no randomness") }
    return b64url(Data(bytes))
}
let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
func form(_ kv: [(String, String)]) -> String { kv.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&") }

let verifier = randomString(48)
let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
let state = randomString(16)

let params = NWParameters.tcp
params.requiredInterfaceType = .loopback
guard let listener = try? NWListener(using: params, on: .any) else { fail("cannot create listener") }

let ready = DispatchSemaphore(value: 0)
let gotCallback = DispatchSemaphore(value: 0)
nonisolated(unsafe) var callback: [String: String] = [:]

listener.stateUpdateHandler = { s in
    switch s {
    case .ready: ready.signal()
    case .failed: fail("listener failed")
    default: break
    }
}
listener.newConnectionHandler = { conn in
    conn.start(queue: .global())
    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
        func reply(_ status: String, _ body: String) {
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body>\(body)</body></html>"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
        guard let data, let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { conn.cancel(); return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]),
              let items = comps.queryItems, items.contains(where: { $0.name == "state" || $0.name == "error" })
        else { reply("404 Not Found", "not found"); return }
        guard callback.isEmpty else { reply("409 Conflict", "already handled"); return }
        for i in items { callback[i.name] = i.value ?? "" }
        reply("200 OK", "InboxBadge probe: you can close this tab.")
        gotCallback.signal()
    }
}
listener.start(queue: .global())
guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else { fail("listener not ready") }
let redirect = "http://127.0.0.1:\(port)"

var authQuery: [(String, String)] = [
    ("client_id", client.client_id),
    ("redirect_uri", redirect),
    ("response_type", "code"),
    ("scope", "openid email https://www.googleapis.com/auth/gmail.modify"),
    ("code_challenge", challenge),
    ("code_challenge_method", "S256"),
    ("state", state),
]
if let hint { authQuery.append(("login_hint", hint)) }
let authURL = "https://accounts.google.com/o/oauth2/v2/auth?" + form(authQuery)

func open(_ url: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [url]
    try? p.run()
    p.waitUntilExit()
}
print("opening the sign-in page in the default browser (consent on the account you want to test)")
open(authURL)

guard gotCallback.wait(timeout: .now() + 300) == .success else { fail("timed out waiting for the browser") }
listener.cancel()
if let err = callback["error"] { fail("authorization error: \(err)") }
guard callback["state"] == state else { fail("state mismatch") }
guard let code = callback["code"] else { fail("no code in callback") }

func send(_ req: URLRequest) -> (Int, [String: Any]) {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: (Int, [String: Any]) = (0, [:])
    URLSession.shared.dataTask(with: req) { d, r, _ in
        let obj = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        out = ((r as? HTTPURLResponse)?.statusCode ?? 0, obj)
        sem.signal()
    }.resume()
    sem.wait()
    return out
}

var tokenReq = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
tokenReq.httpMethod = "POST"
tokenReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
tokenReq.httpBody = Data(form([
    ("client_id", client.client_id), ("client_secret", client.client_secret),
    ("code", code), ("code_verifier", verifier),
    ("grant_type", "authorization_code"), ("redirect_uri", redirect),
]).utf8)
let (tokStatus, tok) = send(tokenReq)
guard tokStatus == 200, let access = tok["access_token"] as? String else {
    fail("token exchange failed: HTTP \(tokStatus) error=\((tok["error"] as? String) ?? "?")")
}
let granted = (tok["scope"] as? String) ?? ""
print("token exchange ok; granted gmail.modify: \(granted.contains("gmail.modify"))")

func gmail(_ path: String) -> (Int, [String: Any]) {
    var r = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!)
    r.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    return send(r)
}

let (pStatus, profile) = gmail("profile")
guard pStatus == 200, let email = profile["emailAddress"] as? String else { fail("profile failed: HTTP \(pStatus)") }
print("account domain: \(email.split(separator: "@").last.map(String.init) ?? "?")")

let (lStatus, label) = gmail("labels/INBOX")
guard lStatus == 200 else { fail("labels.get failed: HTTP \(lStatus)") }
print("INBOX threadsUnread: \(label["threadsUnread"] ?? "?")  threadsTotal: \(label["threadsTotal"] ?? "?")")

for l in ["CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_UPDATES", "CATEGORY_FORUMS", "UNREAD", "SPAM", "TRASH"] {
    let (s, obj) = gmail("labels/\(l)")
    print("\(l) threadsUnread: \(s == 200 ? "\(obj["threadsUnread"] ?? "?")" : "HTTP \(s)")")
}
let (uStatus, unreadInbox) = gmail("threads?labelIds=INBOX&labelIds=UNREAD&maxResults=5")
print("threads.list INBOX+UNREAD: HTTP \(uStatus), \((unreadInbox["threads"] as? [[String: Any]])?.count ?? 0) thread(s)")

let (tStatus, list) = gmail("threads?labelIds=INBOX&maxResults=1")
guard tStatus == 200, let first = (list["threads"] as? [[String: Any]])?.first, let threadId = first["id"] as? String
else { fail("no inbox thread found (HTTP \(tStatus))") }
let (gStatus, thread) = gmail("threads/\(threadId)?format=metadata&metadataHeaders=Message-ID")
guard gStatus == 200 else { fail("threads.get failed: HTTP \(gStatus)") }
let headers = ((thread["messages"] as? [[String: Any]])?.last?["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
let messageID = headers.first { ($0["name"] as? String)?.lowercased() == "message-id" }?["value"] as? String

if ProcessInfo.processInfo.environment["PROBE_NO_LINKS"] != nil { print("counts only; skipping deep links"); exit(0) }
var links = [
    "https://mail.google.com/mail/?authuser=\(enc(email))#inbox/\(threadId)",
    "https://mail.google.com/mail/u/\(enc(email))/#inbox/\(threadId)",
]
if let mid = messageID {
    links.append("https://mail.google.com/mail/?authuser=\(enc(email))#search/rfc822msgid%3A\(enc(mid))")
}
let linksPath = ".probe-links"
FileManager.default.createFile(atPath: linksPath, contents: Data(links.joined(separator: "\n").utf8),
                               attributes: [.posixPermissions: 0o600])
print("opening \(links.count) candidate deep links for the newest inbox thread, 5 s apart (newest tab = last form)")
for (i, l) in links.enumerated() {
    print("form \(i + 1) opened")
    open(l)
    if i < links.count - 1 { Thread.sleep(forTimeInterval: 5) }
}
print("done; record which form numbers open the right thread in the right account")
