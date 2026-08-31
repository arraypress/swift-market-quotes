//
//  Quote.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One priced instrument, whichever market it trades on.
public struct Quote: Codable, Sendable, Equatable {
    /// What kind of thing was priced.
    public enum Kind: String, Codable, Sendable { case crypto, equity }

    /// The symbol as commonly written — `BTC`, `AAPL`.
    public let symbol: String
    /// The listing's full name — "Bitcoin", "Apple Inc." — or the symbol
    /// again when the source withholds one.
    public let name: String
    /// The last price, in ``currency``.
    public let price: Double
    /// Change over the last 24 hours (crypto) or the trading day (equities),
    /// in percent; `nil` when the source did not say.
    public let changePercent: Double?
    /// The price's currency code, lowercase — `usd`, `eur`.
    public let currency: String
    /// Market capitalisation in ``currency``, where the source reports one.
    public let marketCap: Double?
    /// Crypto or equity.
    public let kind: Kind

    /// A quote from a source's values.
    public init(symbol: String, name: String, price: Double, changePercent: Double?,
                currency: String, marketCap: Double?, kind: Kind) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.changePercent = changePercent
        self.currency = currency
        self.marketCap = marketCap
        self.kind = kind
    }
}
