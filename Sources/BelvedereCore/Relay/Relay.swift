import Foundation

/// Inoltro sincrono verso il server di Belvedere, usato dagli eseguibili di supporto.
public enum Relay {
    /// Porta del server: `BELVEDERE_PORT` se impostata, altrimenti quella predefinita.
    public static var port: UInt16 {
        ProcessInfo.processInfo.environment["BELVEDERE_PORT"].flatMap(UInt16.init) ?? Belvedere.defaultPort
    }

    /// Invia il corpo con POST e restituisce la risposta; `nil` se Belvedere non risponde in tempo.
    public static func post(path: String, body: Data, port: UInt16, timeout: TimeInterval) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let result = Box()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result.data = data ?? Data()
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 0.05) == .success else { return nil }
        return result.data
    }

    private final class Box: @unchecked Sendable { var data: Data? }
}
