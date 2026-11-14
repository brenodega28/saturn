import Foundation
import Testing
@testable import EnsembleCore

@Suite struct AppPathsTests {
    @Test func dataDirectoryVariableOverridesApplicationSupport() {
        let paths = AppPaths.resolved(environment: [AppPaths.dataDirectoryVariable: "/tmp/ensemble-scratch"])
        #expect(paths.root.path == "/tmp/ensemble-scratch")
        #expect(paths.database.path == "/tmp/ensemble-scratch/ensemble.sqlite")
    }

    @Test func withoutTheVariableDataLivesInApplicationSupport() {
        let paths = AppPaths.resolved(environment: [AppPaths.dataDirectoryVariable: ""])
        #expect(paths.root == URL.applicationSupportDirectory.appending(path: "Ensemble", directoryHint: .isDirectory))
    }
}

@Suite struct AppDefaultsTests {
    @Test func aCustomDataFolderGetsItsOwnDefaultsSuite() {
        #expect(AppDefaults.suiteName(for: [:]) == nil)
        let one = AppDefaults.suiteName(for: ["ENSEMBLE_DATA_DIR": "/tmp/one"])
        let again = AppDefaults.suiteName(for: ["ENSEMBLE_DATA_DIR": "/tmp/one/"])
        let other = AppDefaults.suiteName(for: ["ENSEMBLE_DATA_DIR": "/tmp/two"])
        #expect(one?.hasPrefix("dev.monoliti.Ensemble.data-dir.") == true)
        #expect(one == again)
        #expect(one != other)
    }
}
