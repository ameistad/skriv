import AppKit
@testable import SkrivCore

@MainActor
enum TestApplication {
    // Match app startup: install the subclass before NSDocument initialization can
    // create a base NSDocumentController. AppKit reuses that first controller.
    static let documents = SkrivDocumentController()
}
