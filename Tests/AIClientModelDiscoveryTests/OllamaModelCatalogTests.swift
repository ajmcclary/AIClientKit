import XCTest
@testable import AIClientModelDiscovery

final class OllamaModelCatalogTests: XCTestCase {
    func test_tagsURL_buildsApiTagsAndToleratesSuffixes() {
        let expected = URL(string: "http://localhost:11434/api/tags")
        XCTAssertEqual(OllamaModelCatalog.tagsURL(from: "http://localhost:11434"), expected)
        XCTAssertEqual(OllamaModelCatalog.tagsURL(from: "http://localhost:11434/"), expected)
        XCTAssertEqual(OllamaModelCatalog.tagsURL(from: "http://localhost:11434/v1"), expected)
        XCTAssertEqual(OllamaModelCatalog.tagsURL(from: "  http://localhost:11434/v1/  "), expected)
    }

    func test_tagsURL_nilForEmpty() {
        XCTAssertNil(OllamaModelCatalog.tagsURL(from: "   "))
    }

    func test_decodeModelNames_parsesModelsArray() throws {
        let json = #"{"models":[{"name":"llama3:latest","size":1},{"name":"qwen2.5:7b"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try OllamaModelCatalog.decodeModelNames(from: json), ["llama3:latest", "qwen2.5:7b"])
    }

    func test_decodeModelNames_emptyModels() throws {
        XCTAssertEqual(try OllamaModelCatalog.decodeModelNames(from: #"{"models":[]}"#.data(using: .utf8)!), [])
    }
}
