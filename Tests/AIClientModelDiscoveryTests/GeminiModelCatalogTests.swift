import XCTest
@testable import AIClientModelDiscovery

final class GeminiModelCatalogTests: XCTestCase {
	func test_decodePage_stripsPrefixAndFiltersToGenerateContent() throws {
		let json = #"""
		{"models":[
		  {"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent","countTokens"]},
		  {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
		  {"name":"models/gemini-3.1-pro-preview","supportedGenerationMethods":["generateContent"]}
		]}
		"""#.data(using: .utf8)!
		let (ids, next) = try GeminiModelCatalog.decodePage(from: json)
		XCTAssertEqual(ids, ["gemini-3.5-flash", "gemini-3.1-pro-preview"])
		XCTAssertNil(next)
	}

	func test_decodePage_surfacesNextPageToken() throws {
		let json = #"{"models":[{"name":"models/gemini-3.5-flash","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"abc123"}"#.data(using: .utf8)!
		let (ids, next) = try GeminiModelCatalog.decodePage(from: json)
		XCTAssertEqual(ids, ["gemini-3.5-flash"])
		XCTAssertEqual(next, "abc123")
	}

	func test_decodePage_missingMethodsIsExcluded() throws {
		let json = #"{"models":[{"name":"models/gemini-legacy"}]}"#.data(using: .utf8)!
		let (ids, _) = try GeminiModelCatalog.decodePage(from: json)
		XCTAssertEqual(ids, [])
	}

	func test_decodePage_emptyAndMalformed() throws {
		XCTAssertEqual(try GeminiModelCatalog.decodePage(from: #"{"models":[]}"#.data(using: .utf8)!).ids, [])
		XCTAssertThrowsError(try GeminiModelCatalog.decodePage(from: #"not json"#.data(using: .utf8)!))
	}
}
