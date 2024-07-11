//
//  StreamVideoModel.swift
//  
//
//  Created by Armaghan on 05/07/2024.
//

import Foundation
protocol Playable {
    var id: String { get }
    var streamURL: URL { get }
    var fileExtension: String { get }
}
struct StreamVideoModel: Playable {
    let id: String
    let streamURL: URL
    let fileExtension: String
    
    let thumbnailURL: URL
}
