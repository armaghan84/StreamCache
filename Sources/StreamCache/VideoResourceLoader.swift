//
//  File.swift
//  
//
//  Created by Armaghan on 05/07/2024.
//

import Foundation
import AVFoundation
import Network
import UIKit

final class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()

    private var bufferData = Data()
    private let downloadBufferLimit = StreamCachePlayerItemConfiguration.downloadBufferLimit
    private let readDataLimit = StreamCachePlayerItemConfiguration.readDataLimit

    private lazy var fileHandle = FileHandler(filePath: saveFilePath)

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var response: URLResponse?
    private let pathMonitor = NWPathMonitor()
    private var pendingRequests = Set<AVAssetResourceLoadingRequest>()
    private var isDownloadComplete = false
    private let queue = DispatchQueue.global(qos: .background)
    private let url: URL
    private let saveFilePath: String
    private var currentOffset: Int64 = 0
    private weak var owner: StreamCachePlayerItem?
    private var initialSetupDone = false
    private var _isConnected: Bool = false {
        didSet {
            if initialSetupDone {
                handleNetworkStatusChange(isConnected: _isConnected)
                
            }
        }
    }
    var isConnected: Bool {
        get {
            return _isConnected
        }
        set {
            _isConnected = newValue
            if initialSetupDone {
                handleNetworkStatusChange(isConnected: _isConnected)
            }
        }
    }
    var networkStatusDidChange: ((Bool) -> Void)?
    // MARK: Init

    init(url: URL, saveFilePath: String, owner: StreamCachePlayerItem?) {
        self.url = url
        self.saveFilePath = saveFilePath
        self.owner = owner
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
        setupPathMonitor()
        // Load existing file data into bufferData
        if let existingData = try? Data(contentsOf: URL(fileURLWithPath: saveFilePath)) {
            bufferData.append(existingData)
        }
    }
   
    deinit {
        invalidateAndCancelSession()
       // networkReachabilityManager?.stopListening()
        pathMonitor.cancel()
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if session == nil {
            // If we're playing from an url, we need to download the file.
            // We start loading the file on first request only.
            startDataRequest(with: url)
        }

        pendingRequests.insert(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingRequests.remove(loadingRequest)
    }

    // MARK: URLSessionDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bufferData.append(data)
        writeBufferDataToFileIfNeeded()
        processPendingRequests()
        currentOffset += Int64(data.count)
        DispatchQueue.main.async {
            self.owner?.delegate?.playerItem?(self.owner!, didDownloadBytesSoFar: self.fileHandle.fileSize, outOf: Int(dataTask.countOfBytesExpectedToReceive))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        processPendingRequests()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if ((error as NSError).code == NSURLErrorNetworkConnectionLost) || ((error as NSError).code == NSURLErrorNotConnectedToInternet) {
                if ((error as NSError).code == NSURLErrorCancelled) {
                    downloadFailed(with: error)
                } else {
                    self.pauseDownload()
                }
               return
            }
            downloadFailed(with: error)
            return
        }

        if bufferData.count > 0 {
            fileHandle.append(data: bufferData)
        }

        let error = verifyResponse()

        guard error == nil else {
            downloadFailed(with: error!)
            return
        }

        downloadComplete()
    }
    private func pauseDownload() {
        lock.lock()
        defer { lock.unlock() }
        if let dataTask = dataTask, dataTask.countOfBytesReceived > 0 {
            dataTask.suspend()
        }
        dataTask?.suspend()
        print("Download paused due to network unavailability.")
    }
    private func resumeDownload() {
        lock.lock()
        defer { lock.unlock() }
        
        if let dataTask = dataTask, dataTask.state == .suspended {
            dataTask.resume()
        } else {
            startDataRequest(with: url)
        }
        print("Download resumed as network is available.")
    }
    // MARK: Internal methods

    func startDataRequest(with url: URL) {
        guard session == nil else { return }

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.timeoutIntervalForRequest = 60
        var urlRequest = URLRequest(url: url)
        owner?.urlRequestHeaders?.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

        // Get the file size to start downloading from where it left off
        let fileSize = fileHandle.fileSize
        if fileSize > 0 {
            urlRequest.setValue("bytes=\(fileSize)-", forHTTPHeaderField: "Range")
        }

        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        dataTask = session?.dataTask(with: urlRequest)
        dataTask?.resume()
        self.initialSetupDone = true
    }

    func invalidateAndCancelSession() {
        session?.invalidateAndCancel()
    }

    // MARK: Private methods

    private func processPendingRequests() {
        lock.lock()
        defer { lock.unlock() }

        // Filter out the unfullfilled requests
        let requestsFulfilled: Set<AVAssetResourceLoadingRequest> = pendingRequests.filter {
            fillInContentInformationRequest($0.contentInformationRequest)
            guard haveEnoughDataToFulfillRequest($0.dataRequest!) else { return false }

            $0.finishLoading()
            return true
        }

        // Remove fulfilled requests from pending requests
        requestsFulfilled.forEach { pendingRequests.remove($0) }
    }

    private func fillInContentInformationRequest(_ contentInformationRequest: AVAssetResourceLoadingContentInformationRequest?) {
        // Do we have response from the server?
        guard let response = response else { return }

        contentInformationRequest?.contentType = response.mimeType
        contentInformationRequest?.contentLength = response.expectedContentLength
        contentInformationRequest?.isByteRangeAccessSupported = true
    }

    private func haveEnoughDataToFulfillRequest(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        let requestedOffset = Int(dataRequest.requestedOffset)
        let requestedLength = dataRequest.requestedLength
        let currentOffset = Int(dataRequest.currentOffset)
        let bytesCached = fileHandle.fileSize

        // Is there enough data cached to fulfill the request?
        guard bytesCached > currentOffset else { return false }

        // Data length to be loaded into memory with maximum size of readDataLimit.
        let bytesToRespond = min(bytesCached - currentOffset, requestedLength, readDataLimit)

        // Read data from disk and pass it to the dataRequest
        guard let data = fileHandle.readData(withOffset: currentOffset, forLength: bytesToRespond) else { return false }
        dataRequest.respond(with: data)

        return bytesCached >= requestedLength + requestedOffset
    }

    private func writeBufferDataToFileIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard bufferData.count >= downloadBufferLimit else { return }

        fileHandle.append(data: bufferData)
        bufferData = Data()
    }

    private func downloadComplete() {
        processPendingRequests()

        isDownloadComplete = true
        DispatchQueue.main.async {
            self.owner?.delegate?.playerItem?(self.owner!, didFinishDownloadingFileAt: self.saveFilePath)
        }
    }

    private func verifyResponse() -> NSError? {
        guard let response = response as? HTTPURLResponse else { return nil }

        let shouldVerifyDownloadedFileSize = StreamCachePlayerItemConfiguration.shouldVerifyDownloadedFileSize
        let minimumExpectedFileSize = StreamCachePlayerItemConfiguration.minimumExpectedFileSize
        var error: NSError?

        if response.statusCode >= 400 {
            error = NSError(domain: "Failed downloading asset. Reason: response status code \(response.statusCode).", code: response.statusCode, userInfo: nil)
        } else if shouldVerifyDownloadedFileSize && response.expectedContentLength != -1 && response.expectedContentLength != fileHandle.fileSize {
            error = NSError(domain: "Failed downloading asset. Reason: wrong file size, expected: \(response.expectedContentLength), actual: \(fileHandle.fileSize).", code: response.statusCode, userInfo: nil)
        } else if minimumExpectedFileSize > 0 && minimumExpectedFileSize > fileHandle.fileSize {
            error = NSError(domain: "Failed downloading asset. Reason: file size \(fileHandle.fileSize) is smaller than minimumExpectedFileSize", code: response.statusCode, userInfo: nil)
        }

        return error
    }

    private func downloadFailed(with error: Error) {
        fileHandle.deleteFile()

        DispatchQueue.main.async {
            self.owner?.delegate?.playerItem?(self.owner!, downloadingFailedWith: error)
        }
    }

    @objc private func handleAppWillTerminate() {
        // We need to only remove the file if it hasn't been fully downloaded
        guard isDownloadComplete == false else { return }
        fileHandle.deleteFile()
    }
}
    // MARK: - Network Reachabilility
extension ResourceLoaderDelegate {
    fileprivate func setupPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                let status = path.status == .satisfied
                if self?.initialSetupDone == true {
                    self?.isConnected = status
                }
            }
        }
        pathMonitor.start(queue: queue)
    }
    fileprivate func handleNetworkStatusChange(isConnected: Bool) {
        if isConnected {
          resumeDownload()
        } else {
           pauseDownload()
        }
    }
}
