import Foundation
import Testing
@testable import InboxCore

struct BasicsTests {
    @Test func pkceMatchesRFC7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func base64URLReplacesUnsafeCharactersAndPadding() {
        #expect(PKCE.base64URL(Data([0xfb, 0xff, 0xbf])) == "-_-_")
        #expect(PKCE.base64URL(Data([0xff])) == "_w")
    }

    @Test func randomTokenIsUrlSafeAndUnique() {
        let a = PKCE.randomToken(bytes: 48), b = PKCE.randomToken(bytes: 48)
        #expect(a.count == 64)
        #expect(a != b)
        #expect(a.allSatisfy { !"+/=".contains($0) })
    }

    @Test func formEscapingEncodesReservedCharacters() {
        #expect(FormEncoding.escape("a b&c=d+e/é") == "a%20b%26c%3Dd%2Be%2F%C3%A9")
        #expect(FormEncoding.encode([("k", "v w"), ("x", "1")]) == "k=v%20w&x=1")
    }

    @Test func clientJSONParsesInstalledAndWeb() throws {
        let installed = jsonData(["installed": ["client_id": "a", "client_secret": "b"]])
        let web = jsonData(["web": ["client_id": "c", "client_secret": "d"]])
        #expect(try OAuthClient.fromGoogleJSON(installed) == OAuthClient(clientID: "a", clientSecret: "b"))
        #expect(try OAuthClient.fromGoogleJSON(web) == OAuthClient(clientID: "c", clientSecret: "d"))
    }

    @Test func clientJSONRejectsMissingFields() {
        #expect(throws: InboxError.malformed("client json")) {
            try OAuthClient.fromGoogleJSON(jsonData(["installed": ["client_id": "a"]]))
        }
        #expect(throws: InboxError.malformed("client json")) {
            try OAuthClient.fromGoogleJSON(Data("nope".utf8))
        }
    }

    @Test func senderDisplayName() {
        #expect(SenderName.display("Jane Doe <jane@x.com>") == "Jane Doe")
        #expect(SenderName.display("\"Doe, Jane\" <jane@x.com>") == "Doe, Jane")
        #expect(SenderName.display("<jane@x.com>") == "jane@x.com")
        #expect(SenderName.display("jane@x.com") == "jane@x.com")
        #expect(SenderName.display("  ") == "Unknown sender")
    }

    @Test func deepLinkUsesFormOne() {
        #expect(GmailLinks.thread(email: "me@gmail.com", threadId: "abc").absoluteString
                == "https://mail.google.com/mail/?authuser=me%40gmail.com#inbox/abc")
        #expect(GmailLinks.inbox(email: "me@gmail.com").absoluteString
                == "https://mail.google.com/mail/?authuser=me%40gmail.com#inbox")
        #expect(GmailLinks.spam(email: "me@gmail.com").absoluteString
                == "https://mail.google.com/mail/?authuser=me%40gmail.com#spam")
    }

    @Test func ageFormatBoundaries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func age(_ seconds: Double) -> String { AgeFormat.short(now.addingTimeInterval(-seconds), now: now) }
        #expect(age(-30) == "now")
        #expect(age(59) == "now")
        #expect(age(60) == "1m")
        #expect(age(3599) == "59m")
        #expect(age(3600) == "1h")
        #expect(age(86399) == "23h")
        #expect(age(86400) == "1d")
        #expect(age(604799) == "6d")
        #expect(age(604800) == "1w")
    }
}
