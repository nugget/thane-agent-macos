import Foundation
import Testing
@testable import thane_agent_macos

/// Tests for the pure request-building and error-decoding surface of
/// `NativeAPIClient`. The networked `get(_:)` itself is not unit-tested (per
/// AGENTS.md: network callers don't need tests, the helpers they call do).
struct NativeAPIClientTests {
    private let base = URL(string: "https://thane.example.tld")!

    @Test func makeRequestBuildsURLWithBearerAndAccept() throws {
        let req = try NativeAPIClient.makeRequest(
            baseURL: base, token: "abc123", path: "v1/system", query: [])
        #expect(req.url?.absoluteString == "https://thane.example.tld/v1/system")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func makeRequestOmitsBearerWhenTokenNilOrEmpty() throws {
        let noToken = try NativeAPIClient.makeRequest(
            baseURL: base, token: nil, path: "v1/system", query: [])
        #expect(noToken.value(forHTTPHeaderField: "Authorization") == nil)

        let emptyToken = try NativeAPIClient.makeRequest(
            baseURL: base, token: "", path: "v1/system", query: [])
        #expect(emptyToken.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func makeRequestUsesProvidedAcceptHeader() throws {
        let sse = try NativeAPIClient.makeRequest(
            baseURL: base, token: nil, path: "v1/loops/events", query: [], accept: "text/event-stream")
        #expect(sse.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func makeRequestEncodesQueryItems() throws {
        let req = try NativeAPIClient.makeRequest(
            baseURL: base, token: nil, path: "v1/conversations",
            query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "order", value: "desc"),
            ])
        let url = try #require(req.url?.absoluteString)
        #expect(url.contains("v1/conversations?"))
        #expect(url.contains("limit=50"))
        #expect(url.contains("order=desc"))
    }

    @Test func decodeErrorParsesEnvelope() {
        let data = Data(#"{"error":"resource not found"}"#.utf8)
        let err = NativeAPIClient.decodeError(status: 404, data: data)
        guard case let .server(status, message) = err else {
            Issue.record("expected .server, got \(err)")
            return
        }
        #expect(status == 404)
        #expect(message == "resource not found")
    }

    @Test func decodeErrorFallsBackOnNonJSONOrEmptyBody() {
        let html = NativeAPIClient.decodeError(
            status: 502, data: Data("<html>bad gateway</html>".utf8))
        guard case .httpStatus(502) = html else {
            Issue.record("expected .httpStatus(502), got \(html)")
            return
        }

        let empty = NativeAPIClient.decodeError(status: 500, data: Data())
        guard case .httpStatus(500) = empty else {
            Issue.record("expected .httpStatus(500), got \(empty)")
            return
        }
    }

    @Test func sseDataValueStripsPrefixAndOptionalSpace() {
        #expect(NativeAPIClient.sseDataValue(#"data: {"x":1}"#) == #"{"x":1}"#)
        #expect(NativeAPIClient.sseDataValue(#"data:{"x":1}"#) == #"{"x":1}"#)
        #expect(NativeAPIClient.sseDataValue("event: loop") == nil)
        #expect(NativeAPIClient.sseDataValue(": keep-alive comment") == nil)
    }

    @Test func joinSSEDataJoinsMultiLineElseNil() {
        #expect(NativeAPIClient.joinSSEData([]) == nil)
        #expect(NativeAPIClient.joinSSEData(["a", "b"]) == "a\nb")
    }
}
