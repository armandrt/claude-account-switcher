// swift-tools-version: 6.0
import Foundation
import PackageDescription

// On a Command Line Tools install swift-testing lives outside SwiftPM's search
// paths; scripts/swiftpm.sh exports the real locations, these are the defaults.
let developerFrameworks = ProcessInfo.processInfo.environment["CAS_DEVELOPER_FRAMEWORKS"]
    ?? "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingPlugins = ProcessInfo.processInfo.environment["CAS_TESTING_PLUGINS"]
    ?? "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testingCompileFlags: [String] = ["-F", developerFrameworks, "-plugin-path", testingPlugins]
let testingLinkFlags: [String] = ["-F", developerFrameworks, "-framework", "Testing"]
let testingRPath: [String] = ["-Xlinker", "-rpath", "-Xlinker", developerFrameworks]

let package = Package(
    name: "ClaudeAccountSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "ClaudeAccountSwitcher", targets: ["ClaudeAccountSwitcher"]),
    ],
    targets: [
        .target(
            name: "SwitcherCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Everything the app does, minus the process itself.  The state machine
        // (AppModel, the sweep, automatic switching, the sign-in) is only
        // testable because it lives in a library rather than in the executable.
        .target(
            name: "SwitcherApp",
            dependencies: ["SwitcherCore"],
            path: "Sources/ClaudeAccountSwitcher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Still named ClaudeAccountSwitcher, so .build/<config>/ClaudeAccountSwitcher
        // is the same path scripts/make-app.sh copies into the bundle.  One file:
        // NSApplication and the delegate SwitcherApp hands it.
        .executableTarget(
            name: "ClaudeAccountSwitcher",
            dependencies: ["SwitcherApp"],
            path: "Sources/ClaudeAccountSwitcherApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The suites are libraries so both `swift test` and Tests/Runner (scripts/test.sh) can host them.
        .target(
            name: "SwitcherCoreTestSuite",
            dependencies: ["SwitcherCore"],
            path: "Tests/SwitcherCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(testingCompileFlags)],
            linkerSettings: [.unsafeFlags(testingLinkFlags)]
        ),
        .target(
            name: "SwitcherAppTestSuite",
            dependencies: ["SwitcherApp", "SwitcherCore"],
            path: "Tests/SwitcherAppTests",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(testingCompileFlags)],
            linkerSettings: [.unsafeFlags(testingLinkFlags)]
        ),
        .executableTarget(
            name: "SwitcherCoreTestRunner",
            dependencies: ["SwitcherCoreTestSuite", "SwitcherAppTestSuite"],
            path: "Tests/Runner",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(testingCompileFlags)],
            linkerSettings: [.unsafeFlags(testingLinkFlags + testingRPath)]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCoreTestSuite", "SwitcherAppTestSuite"],
            path: "Tests/Bridge",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(testingCompileFlags)],
            linkerSettings: [.unsafeFlags(testingLinkFlags + testingRPath)]
        ),
    ]
)
