//
//  Extensions.swift
//  
//
//  Created by Armaghan on 05/07/2024.
//

import Foundation
    // MARK: - Date Extension
extension Date {
    static var mediaDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    var shortDateString: String {
        return Date.mediaDateFormatter.string(from: self)
    }
    
}
    // MARK: - URL Extension
extension URL {
    func withScheme(_ scheme: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }
}
