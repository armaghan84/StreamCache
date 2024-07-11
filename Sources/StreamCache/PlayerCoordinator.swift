//
//  PlayerCoordinator.swift
//  
//
//  Created by Armaghan on 06/07/2024.
//

import Foundation
import AVFoundation
    // MARK: - Alternative Coordinator for SwiftUI View
class PlayerCoordinator: NSObject, ObservableObject, StreamCachePlayerItemDelegate {
    // AVPlayer instance
    @Published var player: AVPlayer?
    
    // Published properties for player state
    @Published var isReadyToPlay: Bool = false
    @Published var playFailedError: Error?
    @Published var PlayingFailed: Bool = false
    @Published var playbackStalled: Bool = false
    @Published var didFinishDownloadingFileAt: String?
    @Published var didFinshedDownload: Bool = false
    @Published var didDownloadBytesSoFar: Int = 0
    @Published var bytesExpected: Int = 0
    
    // CachingPlayerItem instance
    private var cachingPlayerItem: StreamCachePlayerItem?

    // Set with a Playable model
    func setPlayerCoordinator(model: Playable) {
        cachingPlayerItem = StreamCachePlayerItem(model: model)
        cachingPlayerItem?.delegate = self
        player = AVPlayer(playerItem: cachingPlayerItem)
        player?.automaticallyWaitsToMinimizeStalling = false
        self.playVideo()
    }
    func playVideo() {
        player?.seek(to: .zero)
        player?.play()
    }

    // MARK: - CachingPlayerItemDelegate methods

    func playerItemReadyToPlay(_ playerItem: StreamCachePlayerItem) {
        DispatchQueue.main.async {
            self.isReadyToPlay = true
        }
    }

    func playerItemDidFailToPlay(_ playerItem: StreamCachePlayerItem, withError error: Error?) {
        DispatchQueue.main.async {
            self.playFailedError = error
            self.PlayingFailed = true
        }
    }

    func playerItemPlaybackStalled(_ playerItem: StreamCachePlayerItem) {
        DispatchQueue.main.async {
            self.playbackStalled = true
            
        }
    }

    func playerItem(_ playerItem: StreamCachePlayerItem, didFinishDownloadingFileAt filePath: String) {
        DispatchQueue.main.async {
            self.didFinishDownloadingFileAt = filePath
            self.didFinshedDownload = true
        }
    }

    func playerItem(_ playerItem: StreamCachePlayerItem, didDownloadBytesSoFar bytesDownloaded: Int, outOf bytesExpected: Int) {
        DispatchQueue.main.async {
            self.didDownloadBytesSoFar = bytesDownloaded
            self.bytesExpected = bytesExpected
        }
    }

    func playerItem(_ playerItem: StreamCachePlayerItem, downloadingFailedWith error: Error) {
        DispatchQueue.main.async {
            self.playFailedError = error
        }
    }
    func playerItemLocalPlayback(_ playerItem: StreamCachePlayerItem, playing: Bool) {
        DispatchQueue.main.async {
            self.didFinshedDownload = true
        }
    }
    func playerItemfromCachedPlayback(url: URL) {
        
    }
    func playerItemDidFailToPlay(_ playerItem: StreamCachePlayerItem) {
        DispatchQueue.main.async {
            self.PlayingFailed = true
        }
    }
}
