import Foundation

/// Automated runs never read or write the user's preferences or recovery drafts.
/// Each run gets a fresh profile, so even a crash cannot pollute a later session.
enum AppState {
    static let isTesting: Bool = {
        #if WRITE_TESTING
        return true
        #else
        return CommandLine.arguments.contains("--test-mode")
            || ProcessInfo.processInfo.environment["WRITE_TEST_MODE"] == "1"
        #endif
    }()

    private static let testID = UUID().uuidString
    static let defaults: UserDefaults = {
        guard isTesting else { return .standard }
        guard let defaults = UserDefaults(suiteName: "com.grant.write.tests.\(testID)") else {
            fatalError("Cannot create isolated test preferences")
        }
        return defaults
    }()

    static let supportDirectory: URL = {
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("WriteTests-\(testID)", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Write", isDirectory: true)
    }()
}
