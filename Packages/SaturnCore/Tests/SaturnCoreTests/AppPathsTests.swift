import Foundation
import Testing
@testable import SaturnCore

@Suite struct AppPathsTests {
    @Test func dataDirectoryVariableOverridesApplicationSupport() {
        let paths = AppPaths.resolved(environment: [AppPaths.dataDirectoryVariable: "/tmp/saturn-scratch"])
        #expect(paths.root.path == "/tmp/saturn-scratch")
        #expect(paths.database.path == "/tmp/saturn-scratch/saturn.sqlite")
    }

    @Test func theLegacyVariableIsReadAsAFallback() {
        let legacy = AppPaths.resolved(environment: [LegacyMigration.Legacy.dataDirectoryVariable: "/tmp/old-scratch"])
        #expect(legacy.root.path == "/tmp/old-scratch")
        let both = AppPaths.resolved(environment: [AppPaths.dataDirectoryVariable: "/tmp/new", LegacyMigration.Legacy.dataDirectoryVariable: "/tmp/old"])
        #expect(both.root.path == "/tmp/new")
    }

    @Test func withoutTheVariableDataLivesInApplicationSupport() {
        let paths = AppPaths.resolved(environment: [AppPaths.dataDirectoryVariable: ""])
        #expect(paths.root == URL.applicationSupportDirectory.appending(path: "Saturn", directoryHint: .isDirectory))
    }
}

@Suite struct AppDefaultsTests {
    @Test func aCustomDataFolderGetsItsOwnDefaultsSuite() {
        #expect(AppDefaults.suiteName(for: [:]) == nil)
        let one = AppDefaults.suiteName(for: ["SATURN_DATA_DIR": "/tmp/one"])
        let again = AppDefaults.suiteName(for: ["SATURN_DATA_DIR": "/tmp/one/"])
        let other = AppDefaults.suiteName(for: ["SATURN_DATA_DIR": "/tmp/two"])
        #expect(one?.hasPrefix("dev.monoliti.Saturn.data-dir.") == true)
        #expect(one == again)
        #expect(one != other)
    }
}
