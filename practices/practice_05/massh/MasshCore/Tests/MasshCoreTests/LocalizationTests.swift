import Foundation
import Testing
@testable import MasshCore

@Suite("Localization")
struct LocalizationTests {
    /// English is the source language; Russian ships as a translation.
    @Test func errorsHaveEnglishAndRussian() throws {
        let error = ServerStoreError.nameTaken("web-1")
        #expect(error.errorDescription == "Server “web-1” is already in ~/.ssh/config.")

        let ru = try #require(Bundle.module.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        let format = ru.localizedString(forKey: "Server “%@” is already in ~/.ssh/config.", value: nil, table: nil)
        #expect(String(format: format, "web-1") == "Server «web-1» уже есть в ~/.ssh/config.")
    }
}
