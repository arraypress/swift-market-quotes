//
//  Series.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//
//  Turning two very different history shapes into one array of candles.
//
//  Yahoo sends PARALLEL ARRAYS — a list of timestamps beside separate lists
//  of opens, highs, lows, closes and volumes — and any element of any of them
//  can be `null` where a session was halted or the exchange was shut. Dropping
//  the nulls from one array alone silently shifts every later bar onto the
//  wrong day, which is the kind of bug that looks like a bad trading strategy
//  rather than a parsing error. Bars are therefore rejected whole, by index.
//
//  CoinGecko sends the opposite: an array of fixed-length arrays,
//  `[millis, open, high, low, close]`, with no volume at all.
//
//  Verified live 2026-09-05.
//

import Foundation

/// Reads the two history shapes.
enum Series {

    /// Parses Yahoo's chart response.
    static func yahoo(_ data: Data) throws -> [Candle] {
        let response: YahooChart
        do {
            response = try JSONDecoder().decode(YahooChart.self, from: data)
        } catch {
            throw QuotesError.malformed("history: \(error.localizedDescription)")
        }
        guard let result = response.chart.result?.first else {
            throw QuotesError.malformed("history: no result block")
        }
        let quote = result.indicators.quote.first
        let times = result.timestamp ?? []

        return times.indices.compactMap { index -> Candle? in
            // Every field must be present for this index, or the bar is
            // dropped whole — never compacted per-array.
            guard let open = quote?.open?[safe: index] ?? nil,
                  let high = quote?.high?[safe: index] ?? nil,
                  let low = quote?.low?[safe: index] ?? nil,
                  let close = quote?.close?[safe: index] ?? nil
            else { return nil }
            let volume = (quote?.volume?[safe: index] ?? nil).map(Double.init)
            return Candle(time: Date(timeIntervalSince1970: TimeInterval(times[index])),
                          open: open, high: high, low: low, close: close, volume: volume)
        }
    }

    /// Parses CoinGecko's `[millis, o, h, l, c]` rows.
    static func coinGecko(_ data: Data) throws -> [Candle] {
        let rows: [[Double]]
        do {
            rows = try JSONDecoder().decode([[Double]].self, from: data)
        } catch {
            throw QuotesError.malformed("coin history: \(error.localizedDescription)")
        }
        return rows.compactMap { row in
            guard row.count >= 5 else { return nil }
            return Candle(time: Date(timeIntervalSince1970: row[0] / 1000),
                          open: row[1], high: row[2], low: row[3], close: row[4],
                          volume: nil)
        }
    }

    // MARK: - Yahoo's shape

    private struct YahooChart: Decodable {
        let chart: Chart
        struct Chart: Decodable {
            let result: [Result]?
        }
        struct Result: Decodable {
            let timestamp: [Int]?
            let indicators: Indicators
        }
        struct Indicators: Decodable {
            let quote: [Quote]
        }
        struct Quote: Decodable {
            let open: [Double?]?
            let high: [Double?]?
            let low: [Double?]?
            let close: [Double?]?
            let volume: [Int?]?
        }
    }
}

private extension Array {
    /// Index access that returns `nil` rather than trapping — the parallel
    /// arrays are not guaranteed to be the same length.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
