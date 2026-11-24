import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await self.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
