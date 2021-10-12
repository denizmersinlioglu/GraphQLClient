import Combine
import Foundation
import SwiftyJSON

// MARK: - ApiClient

struct ApiClient {
    
    // MARK: Properties
    
    private let baseURL: () -> String
    private let accessToken: () -> String?
    private let logger = Logger()
    
    // MARK: Life Cycle

    init(
        baseURL: @escaping () -> String,
        accessToken: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }
    
    // MARK: Methods
    
    func perform<T: JSONParsable>(_ operation: GraphQL.Operation, as: T.Type) -> AnyPublisher<T, GraphQL.Error> {
        URLSession.shared.dataTaskPublisher(for: httpRequest(for: operation))
            .handleEvents(
                receiveSubscription: { _ in logRequest(for: operation) },
                receiveOutput: { logResponse(for: operation, output: $0) }
            )
            .tryMap { try JSON(data: $0.data) }
            .mapError { GraphQL.Error($0) }
            .flatMap { json -> AnyPublisher<T, GraphQL.Error> in
                let data = json["data"]
                let errors = json["errors"]
                if data.exists(),
                   let result = T.init(data[operation.parsingKey]) {
                    return Just(result)
                        .setFailureType(to: GraphQL.Error.self)
                        .eraseToAnyPublisher()
                } else if errors.exists(),
                          let error = errors.arrayValue.compactMap(GraphQL.Error.init).first {
                    return Fail(error: error)
                        .eraseToAnyPublisher()
                } else {
                    return Fail(error: GraphQL.Error.somethingWentWrong)
                        .eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: Helpers
    
    private func httpRequest(for operation: GraphQL.Operation) -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: baseURL())!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try? operation.request.json.rawData()
        urlRequest.addValue("application/json", forHTTPHeaderField: "content-type")
        if let token = accessToken() {
            urlRequest.addValue(token, forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }
    
    private func logRequest(for operation: GraphQL.Operation) {
        logger.log(
            "GraphQL Request",
            [
                "Operation: \(operation)",
                "Parameters: \(operation.request.variables)",
            ]
        )
    }
    
    private func logResponse(
        for operation: GraphQL.Operation,
        output: URLSession.DataTaskPublisher.Output
    ) {
        logger.log(
            "GraphQL Response",
            [
                "Status: \((output.response as? HTTPURLResponse)?.statusCode ?? 0)",
                "Operation: \(operation)",
                "Parameters: \(operation.request.variables)",
                "Data: \((try? JSON(data: output.data)) ?? [:])"
            ]
        )
    }
}

// MARK: - GraphQL

enum GraphQL {
    
    struct Request {
        var operationName: String
        var operation: String
        var variables: JSON = [:]
        var json: JSON { JSON(dictionaryValue) }
        
        init(
            operationName: String,
            operation: String,
            variables: JSON = [:]
        ) {
            self.operationName = operationName
            self.operation = operation
            self.variables = variables
        }
        
        var dictionaryValue: [String: Any] {
            var dictionary = [String: Any]()
            dictionary["operationName"] = operationName
            dictionary["query"] = operation
            dictionary["variables"] = variables
            return dictionary
        }
    }
    
    struct Error: Swift.Error {
        var message: String
        
        init(_ message: String) {
            self.message = message
        }
        
        init(_ error: Swift.Error) {
            message = error.localizedDescription
        }
        
        init?(_ json: JSON) {
            guard json.exists() else { return nil }
            message = json["message"].stringValue
        }
        
        static var somethingWentWrong: Self = .init("Something went wrong")
    }
    
    enum Operation {
        case launchesPast(limit: Int)
        
        var request: Request {
            switch self {
            case let .launchesPast(limit):
                return .init(
                    operationName: "LaunchesPast",
                    operation: Query.launchesPast,
                    variables: ["limit": limit]
                )
            }
        }
        
        var parsingKey: String {
            switch self {
            case .launchesPast: return "launchesPast"
            }
        }
    }
    
    enum Query {
        static let launchesPast: String = """
            query LaunchesPast($limit: Int!) {
              launchesPast(limit: $limit) {
                mission_name
                launch_date_local
              }
            }
        """
    }
    
}

// MARK: - Logger

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

// MARK: - JSONParsable

protocol JSONParsable {
    init?(_ json: JSON)
}

extension Array: JSONParsable where Element: JSONParsable {
    init?(_ json: JSON) {
        self = json.arrayValue.compactMap(Element.init)
    }
}

// MARK: - Launch

struct Launch: JSONParsable {
    let missionName: String
    let launchDateLocal: String
    
    init?(_ json: JSON) {
        guard json.exists() else { return nil }
        missionName = json["mission_name"].stringValue
        launchDateLocal = json["launch_date_local"].stringValue
    }
}

// MARK: - Main

let apiClient = ApiClient(
    baseURL: { "https://api.spacex.land/graphql/" },
    accessToken: { nil }
)

let query = apiClient
    .perform(.launchesPast(limit: 10), as: [Launch].self)
    .sink(
        receiveCompletion: { print($0) },
        receiveValue: { result in
            print("\n--- OUTPUT ---")
            print(result.map(\.missionName))
        }
    )
