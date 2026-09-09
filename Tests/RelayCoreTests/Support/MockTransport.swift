import Foundation
@testable import RelayCore

actor MockTransport: HTTPTransport {
    struct Step: Sendable { let status: Int; let json: String; var headers: [String: String] = [:] }
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.timedOut) }
        let step = steps.removeFirst()
        return (Data(step.json.utf8), HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: step.headers)!)
    }
    func count() -> Int { requests.count }
    func last() -> URLRequest? { requests.last }
}
