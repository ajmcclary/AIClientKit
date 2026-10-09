import XCTest
@testable import AIClientModelDiscovery

final class FeatherlessModelCatalogTests: XCTestCase {
    func testURLOmitsEmptyQueryAndSetsParams() {
        let url = FeatherlessModelCatalog.modelsURL(query: "  ", availableOnCurrentPlan: true, page: 1, perPage: 50)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.path, "/v1/models")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertNil(items["q"] ?? nil)
        XCTAssertEqual(items["available_on_current_plan"], "true")
        XCTAssertEqual(items["page"], "1")
        XCTAssertEqual(items["per_page"], "50")
    }

    func testURLIncludesQueryWhenPresent() {
        let url = FeatherlessModelCatalog.modelsURL(query: "qwen3", availableOnCurrentPlan: false, page: 2, perPage: 20)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["q"], "qwen3")
        XCTAssertEqual(items["available_on_current_plan"], "false")
        XCTAssertEqual(items["page"], "2")
    }

    func testDecodeParsesDocSample() throws {
        let json = #"""
        {"data":[{"id":"vicgalle/Roleplay-Llama-3-8B","model_class":"llama3-8b-8k","context_length":8192,"max_completion_tokens":4096}]}
        """#.data(using: .utf8)!
        let models = try FeatherlessModelCatalog.decode(json)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "vicgalle/Roleplay-Llama-3-8B")
        XCTAssertEqual(models[0].context_length, 8192)
        XCTAssertEqual(models[0].max_completion_tokens, 4096)
    }
}
