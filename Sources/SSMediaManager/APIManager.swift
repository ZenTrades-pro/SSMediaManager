import Alamofire
import Foundation
import SwiftUI

public typealias UploadCompletion = (_ json: [String: Any]?, _ data: Data?, _ response: URLResponse?, _ error: Error?, _ indexPath: IndexPath?, _ index: Int?) -> Void

struct APIManager{
    
    var session:Session
    public static var shared = APIManager()
    
    private init(){
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        let rootQueue = DispatchQueue(label: "io.smartserv.session.rootQueue")
        let requestQueue = DispatchQueue(label: "io.smartserv.session.requestQueue")
        let serializationQueue = DispatchQueue(label: "io.smartserv.session.serializationQueue",attributes:.concurrent)
        
        session = Session(configuration: configuration, rootQueue:rootQueue,requestQueue:requestQueue,serializationQueue:serializationQueue,interceptor: RequestInterceptor())
    }

    func getUploadUrl(media:SSMedia, baseS3URL: String,indexPath: IndexPath?, index: Int?, completion:@escaping UploadCompletion){
        var params:[String:Any] = [:]
        if let companyId = UserDefaults.standard.string(forKey: "companyId") {
            params["companyId"] = companyId
        }
        params["contentType"] = media.mimeType
        params["fileName"] = media.name
        params["moduleName"] = media.moduleType.rawValue
        
        // Add metadata to params so backend can include it in presigned URL signature
        if let exifMetadata = media.exifMetadata {
            var metadataHeaders: [String: String] = [:]
            
            if (media.mimeType ?? "").hasPrefix("image") {
                metadataHeaders = EXIFMetadataHelper.convertToS3Headers(exifMetadata: exifMetadata, fileURL: URL(fileURLWithPath: media.filePath ?? ""))
            } else if (media.mimeType ?? "").contains("video") {
                metadataHeaders = EXIFMetadataHelper.convertVideoMetadataToS3Headers(videoMetadata: exifMetadata)
            }
            
            if !metadataHeaders.isEmpty {
                params["metadata"] = metadataHeaders
            }
        }
        
        let request = session.request(baseS3URL,parameters:params)
        debugPrint(request.convertible.urlRequest?.cURL())
        
        request.responseData { responseData in
            processAPIResponse(responseData: responseData,indexPath: indexPath, index: index, completion: completion)
        }
    }
    
    func uploadMediaWith(uploadUrl:String, media:SSMedia,indexPath: IndexPath?, index: Int?, json: [String: Any]?,completion:@escaping UploadCompletion){
        guard let path = media.filePath else {
            completion(nil, nil, nil, NSError(domain: "SSMediaManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Upload failed: filePath is nil"]),
                indexPath, index)
            return
        }
        let url = URL(fileURLWithPath: path)
        var headers = HTTPHeaders()
        headers["Content-Type"] = media.mimeType

        // Add EXIF metadata headers for image uploads
        // These headers must match those sent to backend in getUploadUrl
        if (media.mimeType ?? "").hasPrefix("image"), let exifMetadata = media.exifMetadata {
            let exifHeaders = EXIFMetadataHelper.convertToS3Headers(exifMetadata: exifMetadata, fileURL: URL(fileURLWithPath: path))
            if !exifHeaders.isEmpty {
                for (key, value) in exifHeaders {
                    headers[key] = value
                }
            }
        }

        // Add video metadata headers for video uploads
        // These headers must match those sent to backend in getUploadUrl
        if (media.mimeType ?? "").contains("video"), let videoMetadata = media.exifMetadata {
            let videoHeaders = EXIFMetadataHelper.convertVideoMetadataToS3Headers(videoMetadata: videoMetadata)
            if !videoHeaders.isEmpty {
                for (key, value) in videoHeaders {
                    headers[key] = value
                }
            }
        }

        session.upload(url, to: uploadUrl, method: .put, headers: headers).responseData { data in
            if data.response?.statusCode == 200 {
                completion(json, nil, data.response, nil, indexPath, index)
                return
            }
            if let error = data.error as NSError? {
                debugPrint("Upload error: \(error.localizedDescription)")
                completion(nil, nil, nil, error, indexPath, index)
                return
            }
            completion(nil, nil, nil, NSError(domain: "something went wrong", code: data.response?.statusCode ?? 0), indexPath, index)
        }
    }
    
    func processAPIResponse(responseData:AFDataResponse<Data>,indexPath: IndexPath?, index: Int?, completion:@escaping UploadCompletion){
        if let error = responseData.error as NSError? {
            completion(nil, nil, nil, error,indexPath,index)
            return
        }
        var json: [String:Any]?
        var error: Error?
        guard let data  = responseData.data else{
            completion(nil, nil,responseData.response, nil,indexPath,index)
            return
        }
        (json, error) = self.getJsonFromData(data: data)
        completion(json,data,responseData.response,error,indexPath,index)
    }
    
    func getJsonFromData(data: Data) -> ([String:Any]?, Error?) {
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [String : Any]
           return (json, nil)
        } catch {
            return (nil, error)
        }
    }
}

final class RequestInterceptor: Alamofire.RequestInterceptor{
      var retryLimit = 2
     var isRetrying = false
      let retryErrors = [NSURLErrorTimedOut,NSURLErrorCannotFindHost,NSURLErrorCannotParseResponse,NSURLErrorCannotConnectToHost,NSURLErrorCancelled]
    func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Result<URLRequest, Error>) -> Void) {
        var urlRequest = urlRequest
//        urlRequest.setValue(TimeZone.current.identifier, forHTTPHeaderField: "timezonename")
//        urlRequest.setValue(String(TimeZone.current.timeZoneOffsetInMinutes()), forHTTPHeaderField: "timezone-offset")
        completion(.success(urlRequest))
    }
    
    func retry(_ request: Request, for session: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
        if let urlError = error.asAFError?.underlyingError as? URLError{
            if shouldRetry(request, urlError) {
                debugPrint("retrying>>>")
                completion(.retry)
            } else {
                completion(.doNotRetry)
            }
        }else{
            completion(.doNotRetry)
        }
    }
    
    fileprivate func shouldRetry(_ request: Request, _ urlError: URLError) -> Bool {
        return request.retryCount < self.retryLimit && retryErrors.contains(urlError.errorCode)
    }

    
}


extension URLRequest {
    public func cURL(pretty: Bool = true) -> String {
        let newLine = pretty ? "\\\n" : ""
        let method = (pretty ? "--request " : "-X ") + "\(self.httpMethod ?? "GET") \(newLine)"
        let url: String = (pretty ? "--url " : "") + "\'\(self.url?.absoluteString ?? "")\' \(newLine)"

        var cURL = "curl "
        var header = ""
        var data: String = ""

        if let httpHeaders = self.allHTTPHeaderFields, httpHeaders.keys.count > 0 {
            for (key,value) in httpHeaders {
                header += (pretty ? "--header " : "-H ") + "\'\(key): \(value)\' \(newLine)"
            }
        }

        if let bodyData = self.httpBody, let bodyString = String(data: bodyData, encoding: .utf8),  !bodyString.isEmpty {
            data = "--data '\(bodyString)'"
        }

        cURL += method + url + header + data

        return cURL
    }
}

extension DataRequest {
    public func cURL(pretty: Bool = true) -> String {
        // Try to get the request, if not available yet, use task
        if let urlRequest = self.request {
            return urlRequest.cURL(pretty: pretty)
        } else if let task = self.task, let currentRequest = task.currentRequest {
            return currentRequest.cURL(pretty: pretty)
        }
        return "curl command unavailable (request not yet created)"
    }
}


