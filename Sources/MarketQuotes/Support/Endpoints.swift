//
//  Endpoints.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//
//  Every URL the client asks for, built in one testable place — the
//  query grammar is asserted without a network.
//

import Foundation

/// The two sources' URL grammar.
enum Endpoints {

    /// CoinGecko simple price for a batch of ids.
    static func coinPrice(ids: [String], currency: String) -> URL {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: currency),
            URLQueryItem(name: "include_24hr_change", value: "true"),
            URLQueryItem(name: "include_market_cap", value: "true"),
        ]
        return components.url!
    }

    /// CoinGecko's market-cap table, `limit` clamped to the API's page cap.
    static func markets(currency: String, limit: Int) -> URL {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/coins/markets")!
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: currency),
            URLQueryItem(name: "order", value: "market_cap_desc"),
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 250))),
            URLQueryItem(name: "page", value: "1"),
        ]
        return components.url!
    }

    /// CoinGecko text search.
    static func search(_ query: String) -> URL {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/search")!
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        return components.url!
    }

    /// Yahoo's one-day chart, whose metadata carries the live quote.
    static func yahooChart(symbol: String) -> URL? {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escaped)?range=1d&interval=1d")
    }
}

// MARK: - History

extension Endpoints {

    /// Yahoo's chart over a range. The same endpoint the live quote uses —
    /// asking for a wider range fills in the series alongside the metadata.
    static func yahooHistory(symbol: String, range: HistoryRange, interval: HistoryInterval) -> URL? {
        guard let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(escaped)")
        components?.queryItems = [
            URLQueryItem(name: "range", value: range.rawValue),
            URLQueryItem(name: "interval", value: interval.rawValue),
        ]
        return components?.url
    }

    /// CoinGecko's OHLC series. Takes a number of days, not a label, and
    /// chooses its own granularity from it — there is no interval parameter.
    static func coinHistory(id: String, currency: String, days: Int) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/coins/\(escaped)/ohlc")
        components?.queryItems = [
            URLQueryItem(name: "vs_currency", value: currency),
            URLQueryItem(name: "days", value: String(days)),
        ]
        return components?.url
    }
}
