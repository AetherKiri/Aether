import Foundation

/// One VNDB search result, reduced to what the cover picker needs.
struct CoverCandidate: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL
    let thumbnailURL: URL
}

enum CoverSearchError: LocalizedError {
    case emptyTitle, unavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "The game title is empty."
        case .unavailable: return "The cover service is unavailable."
        case .invalidResponse: return "The cover service returned an unexpected response."
        }
    }
}

/// A network cover lookup, injected so tests can supply a fake.
protocol CoverSearchProviding {
    func search(title: String) async throws -> [CoverCandidate]
}

/// Loads raw image bytes for a candidate; injected for tests.
protocol CoverImageLoading {
    func load(_ url: URL) async throws -> Data
}

/// VNDB's public Kana API. Only the game title is sent; no local path, save or
/// account data leaves the device, and the lookup runs only on an explicit user
/// action.
struct VNDBCoverSearch: CoverSearchProviding {
    static let endpoint = URL(string: "https://api.vndb.org/kana/vn")!
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    /// Builds the documented Kana request. Only the title is included.
    static func makeRequest(title: String) throws -> URLRequest {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoverSearchError.emptyTitle }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filters": ["search", "=", trimmed],
            "fields": "id,title,image.url,image.thumbnail",
        ])
        return request
    }

    /// Parses a Kana response, dropping rows without an image.
    static func parse(_ data: Data) throws -> [CoverCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else {
            throw CoverSearchError.invalidResponse
        }
        return results.compactMap { row in
            guard let id = row["id"] as? String, let title = row["title"] as? String,
                  let image = row["image"] as? [String: Any],
                  let urlString = image["url"] as? String, let url = URL(string: urlString) else { return nil }
            let thumbnail = (image["thumbnail"] as? String).flatMap(URL.init(string:)) ?? url
            return CoverCandidate(id: id, title: title, imageURL: url, thumbnailURL: thumbnail)
        }
    }

    func search(title: String) async throws -> [CoverCandidate] {
        let request = try Self.makeRequest(title: title)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CoverSearchError.unavailable
        }
        return try Self.parse(data)
    }
}

struct URLSessionCoverImageLoader: CoverImageLoading {
    let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func load(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw CoverSearchError.unavailable
        }
        return data
    }
}
