import Foundation
import Testing
@testable import thane_agent_macos

struct PlatformRemindersTests {
    @Test
    func listRequestDecodesFromParams() throws {
        let json = Data(#"""
        {"list_names":["Work","Home"],"completed":false,"due_start":"2026-04-02T00:00:00Z","due_end":"2026-04-03T00:00:00Z","query":"taxes","limit":10}
        """#.utf8)
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: json)

        let request = try decodePlatformParams(RemindersListRequest.self, from: params)

        #expect(request.listNames == ["Work", "Home"])
        #expect(request.completed == false)
        #expect(request.dueStart == "2026-04-02T00:00:00Z")
        #expect(request.dueEnd == "2026-04-03T00:00:00Z")
        #expect(request.query == "taxes")
        #expect(request.limit == 10)
    }

    @Test
    func listRequestDefaultsAreNilWhenAbsent() throws {
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: Data("{}".utf8))

        let request = try decodePlatformParams(RemindersListRequest.self, from: params)

        #expect(request.listNames == nil)
        #expect(request.completed == nil)
        #expect(request.dueStart == nil)
        #expect(request.dueEnd == nil)
        #expect(request.query == nil)
        #expect(request.limit == nil)
    }

    @Test
    func dueBoundsAreNilWhenUnset() throws {
        let request = RemindersListRequest(
            listNames: nil, completed: nil, dueStart: nil, dueEnd: nil, query: nil, limit: nil
        )

        let bounds = try request.validatedDueBounds()

        #expect(bounds.start == nil)
        #expect(bounds.end == nil)
    }

    @Test
    func dueBoundsParseBothEnds() throws {
        let request = RemindersListRequest(
            listNames: nil,
            completed: nil,
            dueStart: "2026-04-02T00:00:00Z",
            dueEnd: "2026-04-03T00:00:00Z",
            query: nil,
            limit: nil
        )

        let bounds = try request.validatedDueBounds()

        #expect(bounds.start != nil)
        #expect(bounds.end != nil)
        #expect(bounds.end!.timeIntervalSince(bounds.start!) == 86400)
    }

    @Test
    func dueBoundsRejectBackwardsWindow() {
        let request = RemindersListRequest(
            listNames: nil,
            completed: nil,
            dueStart: "2026-04-03T00:00:00Z",
            dueEnd: "2026-04-02T00:00:00Z",
            query: nil,
            limit: nil
        )

        do {
            _ = try request.validatedDueBounds()
            Issue.record("Expected validatedDueBounds() to reject a backwards window.")
        } catch let error as RemindersServiceError {
            #expect(error.code == "invalid_window")
        } catch {
            Issue.record("Expected RemindersServiceError.invalidWindow, got \(error.localizedDescription)")
        }
    }

    @Test
    func dueBoundsRejectMalformedTimestamp() {
        let request = RemindersListRequest(
            listNames: nil,
            completed: nil,
            dueStart: "not-a-date",
            dueEnd: nil,
            query: nil,
            limit: nil
        )

        do {
            _ = try request.validatedDueBounds()
            Issue.record("Expected validatedDueBounds() to reject a malformed timestamp.")
        } catch let error as RemindersServiceError {
            #expect(error.code == "invalid_timestamp")
        } catch {
            Issue.record("Expected RemindersServiceError.invalidTimestamp, got \(error.localizedDescription)")
        }
    }

    @Test
    @MainActor
    func routerPreservesRemindersErrorCode() async {
        let router = PlatformServiceRouter()
        router.register(capability: "macos.reminders", handler: FailingRemindersHandler())

        let response = await router.handle(request: PlatformRequest(
            id: 9,
            type: "platform_request",
            capability: "macos.reminders",
            method: "list_reminders",
            params: nil
        ))

        #expect(response.success == false)
        #expect(response.error?.code == "reminders_access_denied")
        #expect(response.error?.message == "Reminders access was denied.")
    }
}

private struct FailingRemindersHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_reminders"]

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        throw RemindersServiceError.accessDenied
    }
}
