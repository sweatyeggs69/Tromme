import Foundation

enum PlexAPIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case networkError(Error)
    case decodingError(Error, path: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .unauthorized: return "Authentication required"
        case .serverError(let code): return "Server error (\(code))"
        case .networkError(let error): return error.localizedDescription
        case .decodingError(let error, let path):
            if let decodingError = error as? DecodingError {
                return "Parse error at \(path): \(decodingError.detailedDescription)"
            }
            return "Parse error at \(path): \(error.localizedDescription)"
        }
    }
}

extension DecodingError {
    var detailedDescription: String {
        switch self {
        case .keyNotFound(let key, let context):
            "Missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(let type, let context):
            "Expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(let type, let context):
            "Null value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            "Invalid data at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            localizedDescription
        }
    }
}
