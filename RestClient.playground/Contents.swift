import Foundation
import SwiftyJSON
import PromiseKit

// MARK: - ApiTargetProtocol

protocol ApiTargetProtocol {
    var request: API.Request { get }
    var retryCount: Int { get }
}

extension ApiTargetProtocol {
    var retryCount: Int { 2 }
}

// MARK: - ApiClientProtocol

protocol ApiClientProtocol {
    func request(_ target: ApiTargetProtocol) -> Promise<JSON>
}

// MARK: - API

enum API {
    
    
    struct Client: ApiClientProtocol {
        
        // MARK: Properties
        
        private let baseURL: () -> String
        private let customHeaders: () -> [String: String]?
        private let logger = Logger()

        // Authentication
        private let accessToken: () -> String?
        private let tokenUpdateHandler: (_ target: ApiTargetProtocol) -> Promise<String>
        private let invalidAuthenticationHandler: (_ target: ApiTargetProtocol) -> Void
        
        // MARK: Life Cycle
        
        init(
            baseURL: @escaping () -> String,
            accessToken: @escaping () -> String?,
            customHeaders: @escaping () -> [String: String]?,
            tokenUpdateHandler: @escaping (_ target: ApiTargetProtocol) -> Promise<String>,
            invalidAuthenticationHandler: @escaping (_ target: ApiTargetProtocol) -> Void
        ) {
            self.baseURL = baseURL
            self.accessToken = accessToken
            self.customHeaders = customHeaders
            self.tokenUpdateHandler = tokenUpdateHandler
            self.invalidAuthenticationHandler = invalidAuthenticationHandler
        }
        
        // MARK: Methods
        
        func request(_ target: ApiTargetProtocol) -> Promise<JSON> {
            request(target, retryCount: target.retryCount)
        }
        
        private func request(_ target: ApiTargetProtocol, retryCount: Int) -> Promise<JSON> {
            Promise { seal in
                logRequest(for: target)
                
                URLSession.shared.dataTask(with: httpRequest(for: target)) { data, response, error in
                    self.logResponse(for: target, data: data, response: response)
                    if let error = error { seal.reject(error); return }
                    
                    guard (response as? HTTPURLResponse)?.statusCode != 403 else {
                        if retryCount < 1 {
                            self.invalidAuthenticationHandler(target)
                            seal.reject(API.Error(title: "Invalid authentication"))
                        } else {
                            self.tokenUpdateHandler(target)
                                .then { _ in self.request(target, retryCount: retryCount - 1) }
                                .done { json in seal.fulfill(json) }
                                .catch { error in seal.reject(error) }
                        }
                        return
                    }
                    
                    self.parse(data: data)
                        .done { seal.fulfill($0) }
                        .catch { seal.reject($0) }
                    
                }.resume()
            }
        }
        
    }
    
}

// MARK: - API.Client + Helpers

extension API.Client {
    
    private func parse(data: Data?) -> Promise<JSON> {
        guard let data = data else {
            return .init(error: API.Error(title: "Invalid data"))
        }
        
        do {
            let json = try JSON(data: data)
            return .value(json)
        } catch {
            return .init(error: API.Error(title: "Parsing error"))
        }
        
    }
    
    private func httpRequest(for target: ApiTargetProtocol) -> URLRequest {
        // Path + Parameters
        let request = target.request
        var urlComponents = URLComponents(string: baseURL() + target.request.endPoint)!
        
        if request.encoding == .query {
            let parameters = request.parameters
            urlComponents.queryItems = parameters.map { URLQueryItem(name: $0, value: "\($1)") }
        }
        
        var urlRequest = URLRequest(url: urlComponents.url!)
        urlRequest.httpMethod = request.method.rawValue
        
        if request.encoding == .body {
            urlRequest.httpBody = try? JSON(target.request.parameters).rawData()
        }
        
        // Headers
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        
        if let accessToken = accessToken() {
            urlRequest.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        
        if let customHeaders = customHeaders() {
            customHeaders.forEach { urlRequest.addValue($0, forHTTPHeaderField: $1) }
        }
        
        return urlRequest
    }
    
    private func logRequest(for target: ApiTargetProtocol) {
        logger.log(
            "Api Request",
            [
                "URL: \(baseURL() + target.request.endPoint)",
                "Method: \(target.request.method.rawValue)",
                "Target: \(target)",
                "Parameters: \(target.request.parameters)"
            ]
        )
    }
    
    private func logResponse(
        for target: ApiTargetProtocol,
        data: Data?,
        response: URLResponse?
    ) {
        logger.log(
            "Api Response",
            [
                "URL: \(baseURL() + target.request.endPoint)",
                "Method: \(target.request.method.rawValue)",
                "Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)",
                "Target: \(target)",
                "Parameters: \(target.request.parameters)",
                "Data: \((try? JSON(data: data ?? JSON([:]).rawData())) ?? [:])"
            ]
        )
    }
}

// MARK: - API + Request

extension API {
    
    struct Request {
        var method: Method
        var endPoint: String
        var parameters: [String: Any]
        var encoding: ParameterEncoding
        
        init(
            method: Method,
            endPoint: String,
            parameters: [String: Any] = [:],
            encoding: ParameterEncoding? = nil
        ) {
            self.method = method
            self.endPoint = endPoint
            self.parameters = parameters
            
            switch method {
            case .get, .delete: self.encoding = encoding ?? .query
            case .put, .post: self.encoding = encoding ?? .body
            }
        }
        
        enum Method: String {
            case post = "POST"
            case get = "GET"
            case put = "PUT"
            case delete = "DELETE"
        }
        
        enum ParameterEncoding {
            case body
            case query
        }
    }
    
}

// MARK: - API + Error

extension API {
    
    struct Error: Swift.Error, Codable {
        var title: String
        var message: String
        
        init(_ error: Swift.Error) {
            title = error.localizedDescription
            message = ""
        }
        
        init(title: String, message: String = "") {
            self.title = title
            self.message = message
        }
        
        init?(_ json: JSON) {
            title = json[CodingKeys.title].stringValue
            message = json[CodingKeys.message].stringValue
        }
        
        enum CodingKeys: String, CodingKey {
            case title
            case message
        }
    }
    
}

// MARK: Logger

struct Logger {
    
    func log(_ info: String) {
        print(info)
    }
    
    func log(_ title: String, _ info: [String]) {
        log("\n----- \(title) -----\n\(info.joined(separator: "\n"))\n")
    }
    
    func log(_ title: String, _ info: String) {
        log("\n----- \(title) -----\n\([info])\n")
    }
    
}

// MARK: - JSON + Extensions

extension JSON {
    
    subscript(codingKey: CodingKey) -> JSON {
        get { self[codingKey.stringValue] }
        set { self[codingKey.stringValue] = newValue }
    }
    
}

// MARK: - Targets

extension API {
    
    enum PostTarget: ApiTargetProtocol {
        case get(userId: String)
        
        var request: API.Request {
            switch self {
            case let .get(contentId):
                return .init(
                    method: .get,
                    endPoint: "/posts",
                    parameters: ["userId": contentId]
                )
            }
        }
    }
    
}

// MARK: - Demo

var accessToken: String = ""

let apiClient: ApiClientProtocol = API.Client(
    baseURL: { "https://jsonplaceholder.typicode.com" },
    accessToken: { "Bearer " + accessToken },
    customHeaders: { [:] },
    tokenUpdateHandler: { _ in
        // Refresh access token
        let refreshedToken = ""
        return .value(refreshedToken)
    },
    invalidAuthenticationHandler: { _ in
        // Perform authentication invalidation actions
        accessToken = ""
    }
)

apiClient
    .request(API.PostTarget.get(userId: "1"))
    .done { _ in }

