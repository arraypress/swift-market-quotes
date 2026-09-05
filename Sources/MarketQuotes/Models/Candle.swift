//
//  Candle.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// One bar of price history.
public struct Candle: Codable, Sendable, Equatable {
    /// The bar's opening instant, UTC.
    public let time: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    /// Units traded. Absent on coin history — CoinGecko's OHLC endpoint
    /// carries no volume, and a zero there would be a lie.
    public let volume: Double?

    public init(time: Date, open: Double, high: Double, low: Double,
                close: Double, volume: Double? = nil) {
        self.time = time
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
    }

    /// Close minus open, as a percentage of open.
    public var changePercent: Double? {
        guard open != 0 else { return nil }
        return (close - open) / open * 100
    }

    /// Whether the bar closed above its open.
    public var isUp: Bool { close >= open }
}

/// How far back to look.
public enum HistoryRange: String, Sendable, CaseIterable {
    case day = "1d"
    case fiveDays = "5d"
    case month = "1mo"
    case threeMonths = "3mo"
    case sixMonths = "6mo"
    case year = "1y"
    case twoYears = "2y"
    case fiveYears = "5y"
    case max

    /// Roughly how many days this covers — used to pick a coin endpoint's
    /// `days` parameter, which takes a number rather than a label.
    var approximateDays: Int {
        switch self {
        case .day: return 1
        case .fiveDays: return 5
        case .month: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .year: return 365
        case .twoYears: return 730
        case .fiveYears: return 1_825
        case .max: return 3_650
        }
    }
}

/// How wide each bar is.
public enum HistoryInterval: String, Sendable, CaseIterable {
    case minute = "1m"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case hour = "1h"
    case day = "1d"
    case week = "1wk"
    case month = "1mo"

    /// Yahoo rejects an interval finer than the range can carry — a minute
    /// bar over five years is not a request it will answer. This is the
    /// finest it allows for a given range.
    static func finestAllowed(for range: HistoryRange) -> HistoryInterval {
        switch range {
        case .day, .fiveDays: return .minute
        case .month: return .fifteenMinutes
        case .threeMonths, .sixMonths, .year, .twoYears: return .day
        case .fiveYears, .max: return .week
        }
    }

    /// Whether this interval is finer than the range permits.
    func isTooFine(for range: HistoryRange) -> Bool {
        let order: [HistoryInterval] = [.minute, .fiveMinutes, .fifteenMinutes, .hour, .day, .week, .month]
        guard let mine = order.firstIndex(of: self),
              let finest = order.firstIndex(of: HistoryInterval.finestAllowed(for: range))
        else { return false }
        return mine < finest
    }
}
