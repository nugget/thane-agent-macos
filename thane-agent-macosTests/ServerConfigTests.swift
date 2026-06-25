import Foundation
import Testing
@testable import thane_agent_macos

struct ServerConfigTests {
    @Test func insecurePlaintextHostFlagsRemoteHTTPOnly() {
        // Remote plaintext http:// → flagged (returns the host).
        #expect(ServerConfig.insecurePlaintextHost(in: "http://pocket.hollowoak.net") == "pocket.hollowoak.net")
        #expect(ServerConfig.insecurePlaintextHost(in: "http://pocket.hollowoak.net:8080/v1") == "pocket.hollowoak.net")

        // https:// → fine.
        #expect(ServerConfig.insecurePlaintextHost(in: "https://pocket.hollowoak.net") == nil)

        // localhost / loopback / *.local are ATS-exempt.
        #expect(ServerConfig.insecurePlaintextHost(in: "http://localhost:8080") == nil)
        #expect(ServerConfig.insecurePlaintextHost(in: "http://127.0.0.1:8080") == nil)
        #expect(ServerConfig.insecurePlaintextHost(in: "http://mac.local") == nil)

        // Empty / unparseable → nil.
        #expect(ServerConfig.insecurePlaintextHost(in: "") == nil)
    }
}
