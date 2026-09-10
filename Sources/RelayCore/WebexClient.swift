import Foundation

public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class WebexTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    public override init() { super.init() }
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, WebexClient.isAllowed(url) else { throw RelayError.message("許可されていない通信先です。") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.message("Webexからの応答を解釈できません。") }
        return (data, http)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials to a redirect, including same-host redirects.
        completionHandler(nil)
    }
}

public actor WebexClient {
    private let token: String
    private let transport: any HTTPTransport
    private var retryAfter = Date.distantPast
    public init(token: String, transport: any HTTPTransport = WebexTransport()) {
        self.token = token
        self.transport = transport
    }
    public static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "webexapis.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.path.hasPrefix("/v1/")
    }
    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(string: "https://webexapis.com/v1/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, Self.isAllowed(url) else { throw RelayError.message("Webex URLが不正です。") }
        return url
    }
    private func escaped(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_=".contains($0)) }) else {
            throw RelayError.message("Webex IDが不正です。")
        }
        return id
    }
    private func request(url: URL, method: String = "GET", body: Data? = nil,
                         contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard Self.isAllowed(url) else { throw RelayError.message("ページリンクの通信先が不正です。") }
        try Task.checkCancellation()
        if retryAfter > Date() { throw RelayError.rateLimited(retryAfter.timeIntervalSinceNow) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.perform(request) }
        catch {
            if method == "POST" { throw RelayError.ambiguousSend }
            throw error
        }
        let (data, response) = result
        switch response.statusCode {
        case 200...299: return (data, response)
        case 401: throw RelayError.unauthorized
        case 429:
            let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), now: Date())
            retryAfter = Date().addingTimeInterval(delay)
            throw RelayError.rateLimited(delay)
        case 500...599 where method == "POST": throw RelayError.ambiguousSend
        default: throw RelayError.message("Webex APIエラー（HTTP \(response.statusCode)）。権限と接続を確認してください。")
        }
    }
    public static func retryDelay(_ header: String?, now: Date) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(1, header.flatMap { formatter.date(from: $0) }?.timeIntervalSince(now) ?? 30)
    }
    public func me() async throws -> Person {
        let (data, _) = try await request(url: endpoint("people/me"))
        return try JSONDecoder().decode(Person.self, from: data)
    }
    struct Page<T: Decodable>: Decodable { let items: [T] }
    public static func nextPage(_ link: String?) throws -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            guard part.contains("rel=\"next\"") || part.contains("rel=next") else { continue }
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
                  let url = URL(string: String(part[part.index(after: start)..<end])), isAllowed(url) else {
                throw RelayError.message("Webexのページリンクが不正です。")
            }
            return url
        }
        return nil
    }
    public func rooms(matching filter: String = "") async throws -> [Room] {
        let filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: URL? = try endpoint("rooms", query: [.init(name: "type", value: "direct"),
                                                      .init(name: "sortBy", value: "lastactivity"), .init(name: "max", value: "5")])
        var matches: [Room] = [], visited = Set<URL>(), ids = Set<String>()
        while let url = next {
            guard visited.insert(url).inserted, visited.count <= 2000 else { throw RelayError.message("DM検索のページ数が上限を超えました。条件を変更して再検索してください。") }
            let (data, response) = try await request(url: url)
            try Task.checkCancellation()
            let page = try JSONDecoder().decode(Page<Room>.self, from: data).items
            for room in Room.filtered(page, query: filter) where ids.insert(room.id).inserted {
                matches.append(room)
                // API pages are ordered by last activity; later pages cannot add a newer match.
                if matches.count == 5 { return matches }
            }
            next = try Self.nextPage(response.value(forHTTPHeaderField: "Link"))
        }
        return matches
    }
    public func messages(roomID: String, since: Date? = nil) async throws -> [Message] {
        var next: URL? = try endpoint("messages", query: [.init(name: "roomId", value: roomID), .init(name: "max", value: "100")])
        var all: [Message] = [], visited = Set<URL>(), ids = Set<String>()
        while let url = next {
            guard visited.insert(url).inserted, visited.count <= 100 else { throw RelayError.message("メッセージのページ数が上限を超えました。") }
            let (data, response) = try await request(url: url)
            let page = try JSONDecoder().decode(Page<Message>.self, from: data).items
            all += page.filter { ids.insert($0.id).inserted }
            // A baseline needs only the latest page. Active monitoring traverses all newer pages.
            guard let since, !page.isEmpty, !page.contains(where: { (parseDate($0.created) ?? .distantFuture) < since }) else { break }
            next = try Self.nextPage(response.value(forHTTPHeaderField: "Link"))
        }
        return all
    }
    public func message(id: String) async throws -> Message {
        let (data, _) = try await request(url: endpoint("messages/\(escaped(id))"))
        return try JSONDecoder().decode(Message.self, from: data)
    }
    public func send(roomID: String, text: String, png: Data?, parentID: String? = nil) async throws -> Message {
        _ = try escaped(roomID)
        if let parentID { _ = try escaped(parentID) }
        guard !text.isEmpty, text.utf8.count <= 7000 else { throw RelayError.message("送信本文は1〜7,000 UTF-8バイトで指定してください。") }
        let body: Data, contentType: String
        if let png {
            guard png.count < 10_000_000 else { throw RelayError.message("スクリーンショットが10 MBを超えています。") }
            let boundary = "Relay-\(UUID().uuidString)"
            var multipart = Data()
            func append(_ value: String) { multipart.append(Data(value.utf8)) }
            var fields = [("roomId", roomID), ("text", text)]
            if let parentID { fields.append(("parentId", parentID)) }
            for (name, value) in fields {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"active-window.png\"\r\nContent-Type: image/png\r\n\r\n")
            multipart.append(png)
            append("\r\n--\(boundary)--\r\n")
            body = multipart
            contentType = "multipart/form-data; boundary=\(boundary)"
        } else {
            var fields = ["roomId": roomID, "text": text]
            if let parentID { fields["parentId"] = parentID }
            body = try JSONSerialization.data(withJSONObject: fields)
            contentType = "application/json"
        }
        let (data, _) = try await request(url: endpoint("messages"), method: "POST", body: body, contentType: contentType)
        do { return try JSONDecoder().decode(Message.self, from: data) }
        catch { throw RelayError.ambiguousSend }
    }
}
