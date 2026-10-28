import Foundation

public struct LMStudioModel: Sendable, Equatable {
    public let id: String
    public let loaded: Bool
    public let contextLength: Int?
}

public struct LMStudioStatus: Sendable, Equatable {
    public let reachable: Bool
    public let models: [LMStudioModel]

    public static let offline = LMStudioStatus(reachable: false, models: [])
}

/// Interroga il server locale di LM Studio per sapere quali modelli sono caricati.
public actor LMStudioMonitor {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:1234")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func poll() async -> LMStudioStatus {
        if let data = await get("/api/v0/models") {
            return LMStudioStatus(reachable: true, models: Self.models(data) { item in
                (item["state"] as? String == "loaded", (item["max_context_length"] as? NSNumber)?.intValue)
            })
        }
        if let data = await get("/v1/models") {
            // L'API compatibile OpenAI non dice se il modello è in memoria né il contesto.
            return LMStudioStatus(reachable: true, models: Self.models(data) { _ in (false, nil) })
        }
        return .offline
    }

    private func get(_ path: String) async -> Data? {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 1
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    private static func models(_ data: Data, details: ([String: Any]) -> (Bool, Int?)) -> [LMStudioModel] {
        let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let (loaded, context) = details(item)
            return LMStudioModel(id: id, loaded: loaded, contextLength: context)
        }
    }
}
