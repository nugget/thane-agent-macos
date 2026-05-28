import Contacts
import Foundation
import Testing
@testable import thane_agent_macos

struct PlatformContactsTests {
    @Test
    func makeSummaryExtractsNameAndContactMethods() {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.familyName = "Lovelace"
        contact.organizationName = "Analytical Engines"
        contact.jobTitle = "Mathematician"
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "ada@example.com" as NSString),
        ]
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+15551234567")),
        ]

        let summary = ContactsService.makeSummary(from: contact)

        #expect(summary.name == "Ada Lovelace")
        #expect(summary.givenName == "Ada")
        #expect(summary.familyName == "Lovelace")
        #expect(summary.organization == "Analytical Engines")
        #expect(summary.jobTitle == "Mathematician")
        #expect(summary.emails.map(\.value) == ["ada@example.com"])
        #expect(summary.phones.map(\.value) == ["+15551234567"])
    }

    @Test
    func makeSummaryFallsBackToOrganizationWhenUnnamed() {
        let contact = CNMutableContact()
        contact.organizationName = "Analytical Engines"

        let summary = ContactsService.makeSummary(from: contact)

        #expect(summary.name == "Analytical Engines")
    }

    @Test
    func makeSummaryUsesPlaceholderWhenEmpty() {
        let summary = ContactsService.makeSummary(from: CNMutableContact())

        #expect(summary.name == "(no name)")
        #expect(summary.emails.isEmpty)
        #expect(summary.phones.isEmpty)
        #expect(summary.birthday == nil)
    }

    @Test
    func formatBirthdayIncludesYearWhenPresent() {
        let withYear = ContactsService.formatBirthday(DateComponents(year: 1815, month: 12, day: 10))
        #expect(withYear == "1815-12-10")
    }

    @Test
    func formatBirthdayOmitsYearWhenUndefined() {
        let withoutYear = ContactsService.formatBirthday(DateComponents(month: 12, day: 10))
        #expect(withoutYear == "--12-10")
    }

    @Test
    func formatBirthdayIsNilWithoutMonthOrDay() {
        #expect(ContactsService.formatBirthday(nil) == nil)
        #expect(ContactsService.formatBirthday(DateComponents(year: 1815)) == nil)
    }

    @Test
    func matchesIsCaseInsensitiveAcrossFields() {
        let summary = ContactSummary(
            name: "Ada Lovelace",
            givenName: "Ada",
            familyName: "Lovelace",
            nickname: nil,
            organization: "Analytical Engines",
            jobTitle: nil,
            emails: [ContactLabeledValue(label: "home", value: "ada@example.com")],
            phones: [],
            postalAddresses: [],
            birthday: nil
        )

        #expect(ContactsService.matches(summary: summary, query: "lovelace"))
        #expect(ContactsService.matches(summary: summary, query: "engines"))
        #expect(ContactsService.matches(summary: summary, query: "ada@example.com"))
        #expect(!ContactsService.matches(summary: summary, query: "babbage"))
    }

    @Test
    func searchRequestDecodesFromParams() throws {
        let json = Data(#"{"query":"ada","limit":5}"#.utf8)
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: json)

        let request = try decodePlatformParams(ContactsSearchRequest.self, from: params)

        #expect(request.query == "ada")
        #expect(request.limit == 5)
    }

    @Test
    func searchRequestDefaultsAreNilWhenAbsent() throws {
        let params = try JSONDecoder().decode([String: AnyCodable].self, from: Data("{}".utf8))

        let request = try decodePlatformParams(ContactsSearchRequest.self, from: params)

        #expect(request.query == nil)
        #expect(request.limit == nil)
    }

    @Test
    @MainActor
    func routerPreservesContactsErrorCode() async {
        let router = PlatformServiceRouter()
        router.register(capability: "macos.contacts", handler: FailingContactsHandler())

        let response = await router.handle(request: PlatformRequest(
            id: 7,
            type: "platform_request",
            capability: "macos.contacts",
            method: "search_contacts",
            params: nil
        ))

        #expect(response.success == false)
        #expect(response.error?.code == "contacts_access_denied")
        #expect(response.error?.message == "Contacts access was denied.")
    }
}

private struct FailingContactsHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["search_contacts"]

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        throw ContactsServiceError.accessDenied
    }
}
