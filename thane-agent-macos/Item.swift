//
//  Item.swift
//  thane-agent-macos
//
//  Created by Nugget on 4/1/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
