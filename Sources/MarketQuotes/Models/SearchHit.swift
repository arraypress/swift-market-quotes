//
//  SearchHit.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One listing matching a text search.
public struct SearchHit: Codable, Sendable, Equatable {
    /// CoinGecko's stable id — what ``MarketQuotes`` prices by.
    public let id: String
    /// The trading symbol, uppercase.
    public let symbol: String
    /// The listing's name.
    public let name: String
    /// Market-cap rank; `nil` for unranked listings.
    public let rank: Int?

    public init(id: String, symbol: String, name: String, rank: Int?) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.rank = rank
    }
}
