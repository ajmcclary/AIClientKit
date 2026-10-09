import Foundation
import Synchronization

struct OpenAIWireFixture: Sendable {
	let url: URL
	var configuration: URLSessionConfiguration {
		let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [OpenAIWireURLProtocol.self]; return value
	}
	init(_ bodies: [String], status: Int = 200, hang: Bool = false) {
		url = OpenAIWireURLProtocol.install(bodies.map { .init(body: Data($0.utf8), status: status, hang: hang) })
	}
	var requests: [URLRequest] { OpenAIWireURLProtocol.requests(url.host!) }
	var stops: Int { OpenAIWireURLProtocol.stops(url.host!) }
	func remove() { OpenAIWireURLProtocol.remove(url.host!) }
	func body(_ index: Int = 0) throws -> [String: Any] { try JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data()) as! [String: Any] }
	static let chat = #"{"id":"fixture","choices":[{"index":0,"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}"#
	static func response(_ status: String = "completed") -> String {
		#"{"id":"resp_fixture","object":"response","created_at":1,"model":"fixture","status":""# + status + #"","output":[{"type":"message","id":"msg_fixture","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer","annotations":[]}]}],"usage":{"input_tokens":11,"output_tokens":7,"total_tokens":18},"metadata":{},"parallel_tool_calls":true,"text":{"format":{"type":"text"}},"tool_choice":"none","tools":[]}"#
	}
	static let chatStream = "data: {\"choices\":[{\"delta\":{\"content\":\"hé 🧭\",\"reasoning_content\":\"think\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7,\"total_tokens\":18}}\n\ndata: [DONE]\n\n"
}

final class OpenAIWireURLProtocol: URLProtocol, @unchecked Sendable {
	struct Response: Sendable { let body: Data; let status: Int; let hang: Bool }
	private struct Script: Sendable { var bodies: [Response]; var requests: [URLRequest] = []; var stops = 0 }
	private static let scripts = Mutex<[String: Script]>([:])
	static func install(_ bodies: [Response]) -> URL {
		let host = UUID().uuidString.lowercased()+".fixture.invalid"
		scripts.withLock { $0[host] = Script(bodies: bodies) }; return URL(string: "https://"+host)!
	}
	static func remove(_ host: String) { scripts.withLock { $0[host] = nil } }
	static func requests(_ host: String) -> [URLRequest] { scripts.withLock { $0[host]?.requests ?? [] } }
	static func stops(_ host: String) -> Int { scripts.withLock { $0[host]?.stops ?? 0 } }
	override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".fixture.invalid") == true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func startLoading() {
		guard let url = request.url, let host = url.host else { return }
		var captured = request
		if captured.httpBody == nil, let stream = request.httpBodyStream {
			stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
			while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
			captured.httpBody = data
		}
		let response: Response? = Self.scripts.withLock { scripts in
			guard var script = scripts[host], !script.bodies.isEmpty else { return nil }
			let value = script.bodies.removeFirst(); script.requests.append(captured); scripts[host] = script; return value
		}
		guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
		client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/event-stream"])!, cacheStoragePolicy: .notAllowed)
		for byte in response.body { client?.urlProtocol(self, didLoad: Data([byte])) }
		if !response.hang { client?.urlProtocolDidFinishLoading(self) }
	}
	override func stopLoading() { if let host = request.url?.host { Self.scripts.withLock { $0[host]?.stops += 1 } } }
}
