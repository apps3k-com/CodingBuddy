//
//  Item.swift
//  EnvVarBuddy
//
//  Created by Björn von Känel on 09.06.2026.
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
