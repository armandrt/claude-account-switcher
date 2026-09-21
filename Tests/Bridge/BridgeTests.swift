// The suites live in library targets so they can be linked both into this
// XCTest-hosted bundle (for `swift test` where an xctest host exists) and into
// Tests/Runner (used by scripts/test.sh on a Command Line Tools install).
// swift-testing discovers the tests in the linked images.
@_exported import SwitcherAppTestSuite
@_exported import SwitcherCoreTestSuite
