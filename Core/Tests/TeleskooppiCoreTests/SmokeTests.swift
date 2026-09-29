import Testing
@testable import TeleskooppiCore

@Test func versionIsSet() {
    #expect(!TeleskooppiCore.version.isEmpty)
}
