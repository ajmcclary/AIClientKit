import XCTest
import AIClientKit

final class ReasoningTextFormatterTests: XCTestCase {
	func testNormalizeSeparatesAdjacentBoldSummaryHeaders() {
		let raw = "**Analyzing skill invocation architecture****Planning**"

		XCTAssertEqual(
			ReasoningTextFormatter.normalize(raw),
			"**Analyzing skill invocation architecture**\n\n**Planning**"
		)
	}

	func testNormalizeLeavesLiteralAsteriskRunsUntouched() {
		let raw = "Use **** as a literal marker inside the reasoning body."

		XCTAssertEqual(ReasoningTextFormatter.normalize(raw), raw)
	}

}
