import Foundation
import Synchronization

/// Fixtures are keyed by unique host, so parallel tests never share requests or responses.
struct AnthropicFixture {
	let url: URL
	var configuration: URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [AnthropicFixtureURLProtocol.self]
		return configuration
	}
	init(body: String, status: Int = 200, hang: Bool = false) {
		url = AnthropicFixtureURLProtocol.install(body: Data(body.utf8), status: status, hang: hang)
	}
	var requests: [URLRequest] { AnthropicFixtureURLProtocol.requests(url.host!) }
	var stops: Int { AnthropicFixtureURLProtocol.stops(url.host!) }
	func remove() { AnthropicFixtureURLProtocol.remove(url.host!) }
	func jsonBody() throws -> [String: Any] {
		guard let request = requests.first else { throw URLError(.badServerResponse) }
		var data = request.httpBody ?? Data()
		if let stream = request.httpBodyStream {
			stream.open(); defer { stream.close() }
			var buffer = [UInt8](repeating: 0, count: 1024)
			while stream.hasBytesAvailable {
				let count = stream.read(&buffer, maxLength: buffer.count)
				guard count > 0 else { break }
				data.append(contentsOf: buffer.prefix(count))
			}
		}
		return try JSONSerialization.jsonObject(with: data) as! [String: Any]
	}
	static let completion = #"{"role":"assistant","content":[{"type":"thinking","thinking":"reason"},{"type":"text","text":"answer"}],"usage":{"input_tokens":11,"output_tokens":5,"thinking_tokens":3}}"#
	static let stream = """
	data: {"type":"content_block_start","content_block":{"type":"thinking","thinking":"r"}}

	data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"d"}}

	data: {"type":"content_block_stop"}

	data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hé 🧭"}}

	data: {"type":"message_stop","usage":{"input_tokens":11,"output_tokens":5,"thinking_tokens":3}}


	"""
}

final class AnthropicFixtureURLProtocol: URLProtocol, @unchecked Sendable {
	private struct Script { let body: Data; let status: Int; let hang: Bool; var requests: [URLRequest] = []; var stops = 0 }
	private static let scripts = Mutex<[String: Script]>([:])
	static func install(body: Data, status: Int, hang: Bool) -> URL {
		let host = UUID().uuidString.lowercased() + ".fixture.invalid"
		scripts.withLock { $0[host] = Script(body: body, status: status, hang: hang) }
		return URL(string: "https://" + host)!
	}
	static func remove(_ host: String) { scripts.withLock { $0[host] = nil } }
	static func requests(_ host: String) -> [URLRequest] { scripts.withLock { $0[host]?.requests ?? [] } }
	static func stops(_ host: String) -> Int { scripts.withLock { $0[host]?.stops ?? 0 } }
	override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".fixture.invalid") == true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		guard let url = request.url, let host = url.host else { return }
		let script: Script? = Self.scripts.withLock { scripts in
			guard var script = scripts[host] else { return nil }
			script.requests.append(request); scripts[host] = script; return script
		}
		guard let script else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
		let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		for byte in script.body { client?.urlProtocol(self, didLoad: Data([byte])) }
		if !script.hang { client?.urlProtocolDidFinishLoading(self) }
	}
	override func stopLoading() {
		guard let host = request.url?.host else { return }
		Self.scripts.withLock { $0[host]?.stops += 1 }
	}
}
