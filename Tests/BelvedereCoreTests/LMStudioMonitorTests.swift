import Foundation
import Testing
@testable import BelvedereCore

final class FakeLMStudio: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var offline = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = Self.routes[request.url!.path] ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeLMStudio.self]
        return URLSession(configuration: config)
    }
}

@Suite(.serialized) struct LMStudioMonitorTests {
    @Test func readsNativeAPI() async {
        FakeLMStudio.offline = false
        FakeLMStudio.routes = ["/api/v0/models": (200, #"{"data":[{"id":"qwen3-coder-30b","state":"loaded","max_context_length":65536},{"id":"gemma","state":"not-loaded","max_context_length":8192}]}"#)]
        let status = await LMStudioMonitor(session: FakeLMStudio.session).poll()
        #expect(status.reachable)
        #expect(status.models == [LMStudioModel(id: "qwen3-coder-30b", loaded: true, contextLength: 65536),
                                  LMStudioModel(id: "gemma", loaded: false, contextLength: 8192)])
    }

    @Test func fallsBackToOpenAIAPI() async {
        FakeLMStudio.offline = false
        FakeLMStudio.routes = ["/v1/models": (200, #"{"data":[{"id":"qwen3-coder-30b","object":"model"}]}"#)]
        let status = await LMStudioMonitor(session: FakeLMStudio.session).poll()
        #expect(status.reachable)
        #expect(status.models == [LMStudioModel(id: "qwen3-coder-30b", loaded: false, contextLength: nil)])
    }

    @Test func offline() async {
        FakeLMStudio.offline = true
        let status = await LMStudioMonitor(session: FakeLMStudio.session).poll()
        #expect(status == LMStudioStatus(reachable: false, models: []))
    }
}
