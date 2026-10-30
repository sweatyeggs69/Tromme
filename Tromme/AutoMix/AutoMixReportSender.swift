#if DEBUG
import Foundation

enum AutoMixReportSender {
    private static let url = URL(string: "https://api.tromme.app/report/automix")!

    struct Song: Encodable {
        let key: String
        let title: String
        let artist: String
    }

    struct Report: Encodable {
        let installId: String
        let issue: String
        let details: String
        let previous: Song
        let current: Song
        let result: String
        let values: [String: String]
        let app: String
        let device: String
        let plus: Bool
    }

    enum SendError: Error {
        case rateLimited
        case failed
    }

    static func send(_ report: Report) async throws(SendError) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        guard let body = try? JSONEncoder().encode(report) else { throw .failed }
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw .failed }
        switch status {
        case 201: return
        case 429: throw .rateLimited
        default: throw .failed
        }
    }
}
#endif
