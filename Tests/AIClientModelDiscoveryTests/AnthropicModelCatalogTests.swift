import XCTest
@testable import AIClientModelDiscovery

final class AnthropicModelCatalogTests: XCTestCase {
    func test_decodeModelIDs_parsesDataArray() throws {
        let json = #"{"data":[{"id":"claude-opus-4-8","type":"model"},{"id":"claude-haiku-4-5"}],"has_more":false}"#.data(using: .utf8)!
        XCTAssertEqual(try AnthropicModelCatalog.decodeModelIDs(from: json), ["claude-opus-4-8", "claude-haiku-4-5"])
    }

    func test_decodeModelIDs_emptyData() throws {
        let json = #"{"data":[]}"#.data(using: .utf8)!
        XCTAssertEqual(try AnthropicModelCatalog.decodeModelIDs(from: json), [])
    }

    func test_decodeModelIDs_malformedThrows() {
        let json = #"{"nope":true}"#.data(using: .utf8)!
        XCTAssertThrowsError(try AnthropicModelCatalog.decodeModelIDs(from: json))
    }
}
