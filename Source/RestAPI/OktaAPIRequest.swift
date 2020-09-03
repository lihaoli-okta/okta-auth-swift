/*
 * Copyright (c) 2019, Okta, Inc. and/or its affiliates. All rights reserved.
 * The Okta software accompanied by this notice is provided pursuant to the Apache License, Version 2.0 (the "License.")
 *
 * You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *
 * See the License for the specific language governing permissions and limitations under the License.
 */

import Foundation

/// Constructs and runs Okta API URL request

public class OktaAPIRequest {

    public enum Result {
        case success(OktaAPISuccessResponse)
        case error(OktaError)
    }

    public init(baseURL: URL,
                urlSession: URLSession,
                httpClient: OktaAuthHTTPClient? = nil,
                completion: @escaping (OktaAPIRequest, Result) -> Void) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.httpClient = httpClient
        self.completion = completion
        decoder = JSONDecoder()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        decoder.dateDecodingStrategy = .formatted(formatter)
    }

    public var method: Method = .post
    public var baseURL: URL
    public var path: String?
    public var urlParams: [String: String]?
    public var bodyParams: [String: Any]?
    public var additionalHeaders: [String: String]?
    public var customSuccessHandler: ((OktaAPIRequest, Data?, JSONDecoder, OktaError?) -> Void)?

    public private(set) weak var task: URLSessionDataTask?
    public private(set) var isCancelled: Bool = false

    public enum Method: String {
        case get, post, put, delete, options
    }

    public func buildRequest() -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return nil
        }
        if let path = path {
            components.path = path
        }
        components.queryItems = urlParams?.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            return nil
        }

        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        urlRequest.httpMethod = method.rawValue.uppercased()
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(buildUserAgent(), forHTTPHeaderField: "User-Agent")
        additionalHeaders?.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

        if let bodyParams = bodyParams {
            guard let body = try? JSONSerialization.data(withJSONObject: bodyParams, options: []) else {
                return nil
            }
            urlRequest.httpBody = body
        }

        return urlRequest
    }

    public func run() {
        guard isCancelled == false else {
            return
        }
        guard let urlRequest = buildRequest() else {
            completion(self, .error(.errorBuildingURLRequest))
            return
        }

        if let httpClient = httpClient {
            performRequest(urlRequest, withHTTPClient: httpClient)
        } else {
            performRequest(urlRequest, withURLSession: urlSession)
        }
    }
    
    public func cancel() {
        guard httpClient == nil else {
            isCancelled = true
            return
        }
        guard let task = task else {
            return
        }
        isCancelled = true
        task.cancel()
    }

    // MARK: - Private

    private var urlSession: URLSession
    private var decoder: JSONDecoder
    private var httpClient: OktaAuthHTTPClient?
    private var completion: (OktaAPIRequest, Result) -> Void

    // MARK: Request sending

    internal func performRequest(_ request: URLRequest, withURLSession session: URLSession) {
        guard task == nil else {
            return
        }
        // `self` captured here to keep `OktaAPIRequest` retained until request is finished
        task = session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.handleResponse(
                    data: data,
                    response: response as? HTTPURLResponse,
                    error: error
                )
            }
        }
        task?.resume()
    }

    internal func performRequest(_ request: URLRequest, withHTTPClient httpClient: OktaAuthHTTPClient) {
        // `self` captured here to keep `OktaAPIRequest` retained until request is finished
        httpClient.sendRequest(request) { data, response, error in
            DispatchQueue.main.async {
                self.handleResponse(
                    data: data,
                    response: response,
                    error: error
                )
            }
        }
    }

    // MARK: Response handling

    internal func handleResponse(data: Data?, response: HTTPURLResponse?, error: Error?) {
        guard isCancelled == false else {
            return
        }
        guard error == nil else {
            self.handleResponseError(error: error!)
            return
        }
        guard let data = data, let response = response else {
            callCompletion(.error(.emptyServerResponse))
            return
        }
#if DEBUG
        let json = String(data: data, encoding: .utf8)
        print("\(json ?? "corrupted data")")
#endif
        guard 200 ..< 300 ~= response.statusCode else {
            do {
                let errorResponse = try decoder.decode(OktaAPIErrorResponse.self, from: data)
                callCompletion(.error(.serverRespondedWithError(errorResponse)))
            } catch let e {
                callCompletion(.error(.responseSerializationError(e, data)))
            }
            return
        }
        do {
            if let customSuccessHandler = customSuccessHandler {
                customSuccessHandler(self, data, decoder, nil)
            } else {
                var successResponse = try decoder.decode(OktaAPISuccessResponse.self, from: data)
                successResponse.rawData = data
                callCompletion(.success(successResponse))
            }
        } catch let e {
            callCompletion(.error(.responseSerializationError(e, data)))
        }
    }

    internal func handleResponseError(error: Error) {
        callCompletion(.error(.connectionError(error)))
    }

    internal func callCompletion(_ result: Result) {
        if let customSuccessHandler = customSuccessHandler {
            switch result {
            case .error(let error):
                customSuccessHandler(self, nil, decoder, error)
            case .success(_):
                customSuccessHandler(self, nil, decoder, .internalError("Internal error in OktaAPIRequest class"))
            }
        } else {
            self.completion(self, result)
        }
    }
}
