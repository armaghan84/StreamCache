// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import AVFoundation

@objc public protocol StreamCachePlayerItemDelegate {
    // MARK: Downloading delegate methods
    // Called when the media file is fully downloaded.
    @objc optional func playerItem(_ playerItem: StreamCachePlayerItem, didFinishDownloadingFileAt filePath: String)
    // Called every time a new portion of data is received.
    @objc optional func playerItem(_ playerItem: StreamCachePlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int)
    // Called on downloading error.
    @objc optional func playerItem(_ playerItem: StreamCachePlayerItem, downloadingFailedWith error: Error)

    // MARK: Playing delegate methods
    // Called after initial prebuffering is finished, means we are ready to play.
    @objc optional func playerItemReadyToPlay(_ playerItem: StreamCachePlayerItem)
    // Called when the player is unable to play the data/url.
    @objc optional func playerItemDidFailToPlay(_ playerItem: StreamCachePlayerItem, withError error: Error?)
    
    @objc optional func playerItemDidFailToPlay(_ playerItem: StreamCachePlayerItem)
    // Called when the data being downloaded did not arrive in time to continue playback.
    @objc optional func playerItemPlaybackStalled(_ playerItem: StreamCachePlayerItem)
    
    @objc optional func playerItemLocalPlayback(_ playerItem: StreamCachePlayerItem, playing: Bool)
    
    @objc optional func playerItemfromCachedPlayback(url: URL)
}

public final class StreamCachePlayerItem: AVPlayerItem {
    private let cachingPlayerItemScheme = "StreamCache"

    private lazy var resourceLoaderDelegate = ResourceLoaderDelegate(url: url, saveFilePath: saveFilePath, owner: self)
    private let url: URL
    private let initialScheme: String?
    private let saveFilePath: String
    private var customFileExtension: String?
    internal var urlRequestHeaders: [String: String]?
    fileprivate let lock = NSLock()
    public var passOnObject: Any?
    public weak var delegate: StreamCachePlayerItemDelegate?

    // MARK: Public init
    // Play and cache remote media.
    public init(url: URL, saveFilePath: String, customFileExtension: String?, avUrlAssetOptions: [String: Any]? = nil) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              var urlWithCustomScheme = url.withScheme(cachingPlayerItemScheme) else {
            fatalError("CachingPlayerItem error: Urls without a scheme are not supported")
        }

        self.url = url
        self.saveFilePath = saveFilePath
        self.initialScheme = scheme
        if let ext = customFileExtension {
            urlWithCustomScheme.deletePathExtension()
            urlWithCustomScheme.appendPathExtension(ext)
            self.customFileExtension = ext
        }  else {
            assert(url.pathExtension.isEmpty == false, "CachingPlayerItem error: url pathExtension empty")
        }

        if let headers = avUrlAssetOptions?["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] {
            self.urlRequestHeaders = headers
        }

        let asset = AVURLAsset(url: urlWithCustomScheme, options: avUrlAssetOptions)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)

        asset.resourceLoader.setDelegate(resourceLoaderDelegate, queue: DispatchQueue.main)

        addObservers()
    }

    // Play remote media **without** caching
    public init(nonCachingURL url: URL, avUrlAssetOptions: [String: Any]? = nil) {
        self.url = url
        self.saveFilePath = ""
        self.initialScheme = nil

        let asset = AVURLAsset(url: url, options: avUrlAssetOptions)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)

        addObservers()
    }
    // Play from file.
    public init(filePathURL: URL, fileExtension: String? = nil) {
        if let fileExtension = fileExtension {
            let url = filePathURL.deletingPathExtension()
            self.url = url.appendingPathExtension(fileExtension)

            // Removes old SymLinks which cause issues
            try? FileManager.default.removeItem(at: url)

            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: filePathURL)
        } else {
            assert(filePathURL.pathExtension.isEmpty == false,
                   "CachingPlayerItem error: filePathURL pathExtension empty, pass the extension in `fileExtension` parameter")
            self.url = filePathURL
        }

        // Not needed properties when playing media from a local file.
        self.saveFilePath = ""
        self.initialScheme = nil

        super.init(asset: AVURLAsset(url: url), automaticallyLoadedAssetKeys: nil)

        addObservers()
        
        DispatchQueue.main.async { self.delegate?.playerItemLocalPlayback?(self, playing: true) }
    }


    override public init(asset: AVAsset, automaticallyLoadedAssetKeys: [String]?) {
        self.url = URL(fileURLWithPath: "")
        self.initialScheme = nil
        self.saveFilePath = ""
        super.init(asset: asset, automaticallyLoadedAssetKeys: automaticallyLoadedAssetKeys)

        addObservers()
    }

    deinit {
        removeObservers()

        // Don't reference lazy `resourceLoaderDelegate` if it hasn't been called before.
        guard initialScheme != nil else { return }

        // Otherwise the ResourceLoaderDelegate wont deallocate and will keep downloading.
        resourceLoaderDelegate.invalidateAndCancelSession()
    }
    // MARK: KVO

    private var playerItemContext = 0

    public override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?,
                               context: UnsafeMutableRawPointer?) {

        // Only handle observations for the playerItemContext
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath,
                               of: object,
                               change: change,
                               context: context)
            return
        }

        // We are only observing the status keypath
        guard keyPath == #keyPath(AVPlayerItem.status) else { return }

        let status: AVPlayerItem.Status
        if let statusNumber = change?[.newKey] as? NSNumber {
            status = AVPlayerItem.Status(rawValue: statusNumber.intValue)!
        } else {
            status = .unknown
        }

        // Switch over status value
        switch status {
        case .readyToPlay:
            // Player item is ready to play.
            DispatchQueue.main.async { self.delegate?.playerItemReadyToPlay?(self) }
        case .failed:
            // Player item failed. See error.
            print("CachingPlayerItem status: failed with error: \(String(describing: error))")
            DispatchQueue.main.async { self.delegate?.playerItemDidFailToPlay?(self, withError: self.error) }
        case .unknown:
            // Player item is not yet ready.
            print("CachingPlayerItem status: uknown with error: \(String(describing: error))")
        @unknown default:
            break
        }
    }

    // MARK: Private methods

    private func addObservers() {
        addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: .new, context: &playerItemContext)
        NotificationCenter.default.addObserver(self, selector: #selector(playbackStalledHandler), name: .AVPlayerItemPlaybackStalled, object: self)
    }

    private func removeObservers() {
        removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func playbackStalledHandler() {
        DispatchQueue.main.async { self.delegate?.playerItemPlaybackStalled?(self) }
    }
    
}
extension StreamCachePlayerItem {
    var playable: Playable? {
        passOnObject as? Playable
    }
    
    convenience init(model: Playable) {
        var saveFilePath = try! FileManager.default.url(for: .cachesDirectory,
                                                                 in: .userDomainMask,
                                                                 appropriateFor: nil,
                                                                 create: true)
        saveFilePath = saveFilePath.appendingPathComponent("\(model.id)_\(Date().shortDateString)")
        saveFilePath.appendPathExtension(model.fileExtension)

        if FileManager.default.fileExists(atPath: saveFilePath.path) {
            self.init(filePathURL: saveFilePath)
            print("Playing from cached local file.")
        } else {
            self.init(url: model.streamURL, saveFilePath: saveFilePath.path, customFileExtension: model.fileExtension)
            print("Playing from remote url.")
        }
        self.passOnObject = model
    }
    class func fileURL(in directory: FileManager.SearchPathDirectory, model: Playable) -> URL {
        let directoryURL = try! FileManager.default.url(for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
        var fileURL = directoryURL.appendingPathComponent("\(model.id)_\(Date().shortDateString)")
        fileURL.appendPathExtension(model.fileExtension)
        return fileURL
    }
    func moveFileFromCacheToDocuments() {
        lock.lock()
        defer { lock.unlock() }
        guard let playable = self.playable else { return }
        let cacheFilePath = StreamCachePlayerItem.fileURL(in: .cachesDirectory, model: playable)
        let documentsFilePath = StreamCachePlayerItem.fileURL(in: .documentDirectory, model: playable)
        let fileManager = FileManager.default
        
        if fileManager.fileExists(atPath: cacheFilePath.path) {
            // Move the file from Cache to Documents directory
            do {
                try fileManager.moveItem(at: cacheFilePath, to: documentsFilePath)
                print("File moved from Cache to Documents directory.")
                print(documentsFilePath)
            } catch {
                print("Error moving file: \(error)")
                print(cacheFilePath)
            }
        } else {
            print("File does not exist in the Cache directory.")
        }
    }
    
}
