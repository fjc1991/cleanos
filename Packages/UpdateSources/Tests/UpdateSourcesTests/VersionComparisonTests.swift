import Testing
@testable import UpdateSources

@Suite struct VersionComparisonTests {
    @Test func numericComponents() {
        #expect(VersionComparison.compare("1.2.3", to: "1.2.10") == .older)
        #expect(VersionComparison.compare("2.0", to: "2.0.0") == .same)
        #expect(VersionComparison.compare("10.0.1", to: "9.9.9") == .newer)
    }
    @Test func homebrewRevisionSuffix() {
        #expect(VersionComparison.isNewer("2.56.0_1", than: "2.56.0"))
        #expect(!VersionComparison.isNewer("2.56.0", than: "2.56.0_1"))
    }
    @Test func prereleaseSortsBeforeRelease() {
        #expect(VersionComparison.compare("1.2-beta", to: "1.2") == .older)
        #expect(VersionComparison.compare("1.2", to: "1.2-beta") == .newer)
    }
    @Test func buildNumbersInParentheses() {
        #expect(VersionComparison.compare("7.2.2 (88465)", to: "7.2.2 (88470)") == .older)
    }
}
