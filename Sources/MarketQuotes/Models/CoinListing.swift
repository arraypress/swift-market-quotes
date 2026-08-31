//
//  CoinListing.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One row of the crypto market-cap table.
public struct CoinListing: Codable, Sendable, Equatable {
    /// Market-cap rank, 1 first.
    public let rank: Int
    /// CoinGecko's stable id — `bitcoin`.
    public let id: String
    /// The trading symbol, uppercase — `BTC`.
    public let symbol: String
    /// The listing's name.
    public let name: String
    /// Last price in the asked currency.
    public let price: Double
    /// Market capitalisation in the asked currency.
    public let marketCap: Double
    /// 24-hour change in percent; `nil` when unreported.
    public let changePercent: Double?

    public init(rank: Int, id: String, symbol: String, name: String,
                price: Double, marketCap: Double, changePercent: Double?) {
        self.rank = rank
        self.id = id
        self.symbol = symbol
        self.name = name
        self.price = price
        self.marketCap = marketCap
        self.changePercent = changePercent
    }
}
