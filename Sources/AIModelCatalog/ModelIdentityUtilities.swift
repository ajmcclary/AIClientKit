import Foundation

public enum AIModelStringOrdering {
	public static func compare(
		_ lhs: String,
		_ rhs: String,
		caseInsensitiveASCII: Bool
	) -> ComparisonResult {
		let foldedComparison = compareScalars(
			lhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) },
			rhs.unicodeScalars.map { foldedScalarValue($0.value, caseInsensitiveASCII: caseInsensitiveASCII) }
		)
		if foldedComparison != .orderedSame || !caseInsensitiveASCII {
			return foldedComparison
		}

		return compareScalars(
			lhs.unicodeScalars.map(\.value),
			rhs.unicodeScalars.map(\.value)
		)
	}

	public static func precedes(
		_ lhs: String,
		_ rhs: String,
		caseInsensitiveASCII: Bool = true
	) -> Bool {
		compare(lhs, rhs, caseInsensitiveASCII: caseInsensitiveASCII) == .orderedAscending
	}

	private static func foldedScalarValue(
		_ value: UInt32,
		caseInsensitiveASCII: Bool
	) -> UInt32 {
		guard caseInsensitiveASCII, value >= 65, value <= 90 else { return value }
		return value + 32
	}

	private static func compareScalars(
		_ lhs: [UInt32],
		_ rhs: [UInt32]
	) -> ComparisonResult {
		let count = min(lhs.count, rhs.count)
		for index in 0..<count {
			if lhs[index] == rhs[index] { continue }
			return lhs[index] < rhs[index] ? .orderedAscending : .orderedDescending
		}
		if lhs.count == rhs.count { return .orderedSame }
		return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
	}
}

/// Lowercase-hex encode/decode for embedding arbitrary identity fields (endpoint ids, names,
/// model names, record ids) into delimiter-joined model keys and backend specifiers. Hex output
/// contains only `[0-9a-f]`, so it never collides with `_` / `:` separators. Single source of
/// truth shared by `AIModel` identity keys and `ClaudeCodeAIModelCatalog` specifiers — do not
/// re-implement (the two former copies had already drifted).
public enum AIHexIdentityCoding {
	public static func encode(_ value: String) -> String {
		value.utf8.map { String(format: "%02x", $0) }.joined()
	}

	public static func decode(_ value: String) -> String? {
		guard value.count.isMultiple(of: 2) else { return nil }
		var bytes: [UInt8] = []
		bytes.reserveCapacity(value.count / 2)
		var index = value.startIndex
		while index < value.endIndex {
			let next = value.index(index, offsetBy: 2)
			guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
			bytes.append(byte)
			index = next
		}
		return String(bytes: bytes, encoding: .utf8)
	}
}

