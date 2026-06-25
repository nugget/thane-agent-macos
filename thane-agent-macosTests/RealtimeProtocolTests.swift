import Foundation
import Testing
@testable import thane_agent_macos

/// Tests for the realtime WebSocket contract this app speaks (thane-ai-agent#1081).
///
/// Two load-bearing facts are pinned here so a regression fails CI rather than
/// shipping a silent production failure:
///   1. The `auth` message must carry `protocol":"platform"` (and snake_case
///      keys). On `/v1/realtime/ws` the server selects the request envelope
///      from this field; dropping it would default to the companion envelope,
///      which this client does not decode — killing all server→client dispatch.
///   2. The endpoint URL builder targets the canonical realtime path and
///      upgrades the scheme for the WebSocket upgrade.
struct RealtimeProtocolTests {

    @Test func authMessageEncodesPlatformProtocolAndSnakeCaseKeys() throws {
        let msg = AuthMessage(
            type: "auth",
            token: "secret",
            clientName: "Mac",
            clientID: "cid-123",
            connectionProtocol: WSEndpoint.platformProtocol
        )

        let data = try JSONEncoder().encode(msg)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["protocol"] as? String == "platform")
        #expect(json["type"] as? String == "auth")
        #expect(json["token"] as? String == "secret")
        #expect(json["client_name"] as? String == "Mac")
        #expect(json["client_id"] as? String == "cid-123")

        // camelCase property names must never leak onto the wire.
        #expect(json["clientName"] == nil)
        #expect(json["clientID"] == nil)
        #expect(json["connectionProtocol"] == nil)
    }

    @Test func realtimeURLUpgradesSchemeAndAppendsCanonicalPath() {
        #expect(
            WSEndpoint.realtimeURL(base: URL(string: "https://thane.example.tld")!).absoluteString
                == "wss://thane.example.tld/v1/realtime/ws"
        )
        #expect(
            WSEndpoint.realtimeURL(base: URL(string: "http://localhost:8080")!).absoluteString
                == "ws://localhost:8080/v1/realtime/ws"
        )
    }
}
