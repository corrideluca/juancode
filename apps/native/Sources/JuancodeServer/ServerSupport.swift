import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import JuancodeCore
import JuancodeServices

/// An API error that renders as `{ "error": "<message>" }` with a status code —
/// matching the JSON error bodies the Express server returns in `index.ts`.
struct APIError: HTTPResponseError {
    let status: HTTPResponse.Status
    let message: String

    init(_ status: HTTPResponse.Status, _ message: String) {
        self.status = status
        self.message = message
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        jsonResponse(["error": message], status: status)
    }
}

/// Build a JSON `Response` from any Encodable with an explicit status. Used for
/// the cases the auto `ResponseEncodable` path can't express: a `null` body, a
/// `201`/`204` status, or a raw dictionary.
func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
    return rawJSONResponse(data, status: status)
}

/// A literal-JSON response (e.g. `null` for a missing cached review, matching
/// the TS `res.json(null)`).
func rawJSONResponse(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

let jsonNullResponse = rawJSONResponse(Data("null".utf8))

func errMsg(_ err: Error) -> String {
    if let g = err as? GitError { return g.message }
    if let g = err as? GhError { return g.message }
    if let p = err as? ProcessError { return p.message }
    return (err as? LocalizedError)?.errorDescription ?? "\(err)"
}

// ── ResponseEncodable conformances ───────────────────────────────────────────
// These DTOs live in JuancodeCore / JuancodeServices (which can't depend on
// Hummingbird); conform them here so handlers can return them directly as JSON.

extension SessionMeta: @retroactive ResponseEncodable {}
extension SearchHit: @retroactive ResponseEncodable {}
extension DiffResult: @retroactive ResponseEncodable {}
extension GitState: @retroactive ResponseEncodable {}
extension Worktree: @retroactive ResponseEncodable {}
extension CommitResult: @retroactive ResponseEncodable {}
extension PushResult: @retroactive ResponseEncodable {}
extension CommitMessageResult: @retroactive ResponseEncodable {}
extension PrCreateResult: @retroactive ResponseEncodable {}
extension PrListResult: @retroactive ResponseEncodable {}
extension BeadsResult: @retroactive ResponseEncodable {}
extension ReviewResult: @retroactive ResponseEncodable {}
extension DiffComment: @retroactive ResponseEncodable {}
extension ProviderStatus: @retroactive ResponseEncodable {}
