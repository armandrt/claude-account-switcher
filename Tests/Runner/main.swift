import SwitcherAppTestSuite
import SwitcherCoreTestSuite
import Testing

// This machine has Command Line Tools and no Xcode, so there is no `xctest`
// host to run a .xctest bundle: `swift test` builds the bundle and then exits
// 0 without running a single test.  This runner hosts swift-testing itself, so
// scripts/test.sh reports real results and a real exit code.  Both suites are
// linked in: the core one and the app target's.  On a machine with
// Xcode, `swift test` runs the same suite through the bridge test target.
await Testing.__swiftPMEntryPoint() as Never
