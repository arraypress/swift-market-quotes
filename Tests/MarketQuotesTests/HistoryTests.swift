//
//  HistoryTests.swift
//  MarketQuotesTests
//
//  Created by David Sherlock on 2026.
//
//  The two history shapes, and the misalignment trap in the first of them.
//

import Foundation
import XCTest
@testable import MarketQuotes

final class HistoryTests: XCTestCase {

    // MARK: - Yahoo's parallel arrays

    /// The bug this guards against: a halted session leaves a `null` in one
    /// array only. Compacting that array on its own shifts every later bar
    /// onto the wrong day — which looks like a bad strategy, not a parse bug.
    func testABarWithAnyMissingFieldIsDroppedWholeSoTheRestStayAligned() throws {
        let candles = try Series.yahoo(Data("""
        { "chart": { "result": [ {
            "timestamp": [1788000000, 1788086400, 1788172800],
            "indicators": { "quote": [ {
              "open":   [100.0, null,  102.0],
              "high":   [101.0, 105.0, 103.0],
              "low":    [ 99.0, 104.0, 101.0],
              "close":  [100.5, 104.5, 102.5],
              "volume": [1000,  2000,  3000] } ] } } ] } }
        """.utf8))

        XCTAssertEqual(candles.count, 2, "the middle bar has no open and must go entirely")
        XCTAssertEqual(candles[0].time, Date(timeIntervalSince1970: 1_788_000_000))
        XCTAssertEqual(candles[1].time, Date(timeIntervalSince1970: 1_788_172_800),
                       "the surviving bar keeps its OWN timestamp, not the dropped one's")
        XCTAssertEqual(candles[1].open, 102.0)
        XCTAssertEqual(candles[1].close, 102.5)
    }

    func testAFullYahooSeriesReadsOpenHighLowCloseAndVolume() throws {
        let candles = try Series.yahoo(Data("""
        { "chart": { "result": [ {
            "timestamp": [1788000000],
            "indicators": { "quote": [ {
              "open": [316.85], "high": [325.13], "low": [316.0],
              "close": [324.96], "volume": [45000000] } ] } } ] } }
        """.utf8))

        let bar = try XCTUnwrap(candles.first)
        XCTAssertEqual(bar.open, 316.85)
        XCTAssertEqual(bar.high, 325.13)
        XCTAssertEqual(bar.low, 316.0)
        XCTAssertEqual(bar.close, 324.96)
        XCTAssertEqual(bar.volume, 45_000_000)
        XCTAssertTrue(bar.isUp)
        XCTAssertEqual(bar.changePercent ?? 0, 2.56, accuracy: 0.01)
    }

    func testShorterParallelArraysDoNotTrap() throws {
        // Nothing guarantees the arrays are the same length.
        let candles = try Series.yahoo(Data("""
        { "chart": { "result": [ {
            "timestamp": [1788000000, 1788086400],
            "indicators": { "quote": [ {
              "open": [100.0], "high": [101.0], "low": [99.0], "close": [100.5] } ] } } ] } }
        """.utf8))
        XCTAssertEqual(candles.count, 1)
        XCTAssertNil(candles.first?.volume, "no volume array means no volume, not zero")
    }

    // MARK: - CoinGecko's row arrays

    func testCoinRowsAreFixedLengthArraysInMillisecondsAndCarryNoVolume() throws {
        let candles = try Series.coinGecko(Data("""
        [ [1788004800000, 77634.0, 77738.0, 77498.0, 77584.0],
          [1788019200000, 77584.0, 78103.0, 77536.0, 77854.0] ]
        """.utf8))

        XCTAssertEqual(candles.count, 2)
        XCTAssertEqual(candles[0].time, Date(timeIntervalSince1970: 1_788_004_800),
                       "the source is in milliseconds")
        XCTAssertEqual(candles[0].open, 77634.0)
        XCTAssertEqual(candles[0].close, 77584.0)
        XCTAssertNil(candles[0].volume, "the OHLC endpoint sends none, and zero would be a lie")
        XCTAssertFalse(candles[0].isUp)
        XCTAssertTrue(candles[1].isUp)
    }

    func testAShortCoinRowIsSkippedRatherThanTrapping() throws {
        let candles = try Series.coinGecko(Data("[[1788004800000, 1.0, 2.0]]".utf8))
        XCTAssertTrue(candles.isEmpty)
    }

    // MARK: - Interval clamping

    func testAnIntervalFinerThanTheRangeAllowsIsWidenedRatherThanRejected() {
        XCTAssertTrue(HistoryInterval.minute.isTooFine(for: .fiveYears))
        XCTAssertEqual(HistoryInterval.finestAllowed(for: .fiveYears), .week)

        XCTAssertFalse(HistoryInterval.minute.isTooFine(for: .day),
                       "a minute bar over one day is exactly what Yahoo allows")
        XCTAssertFalse(HistoryInterval.day.isTooFine(for: .year))
        XCTAssertTrue(HistoryInterval.minute.isTooFine(for: .year))
    }

    func testTheRequestCarriesTheClampedIntervalNotTheAskedOne() async throws {
        final class Recorder: @unchecked Sendable {
            var requests: [URLRequest] = []
        }
        let recorder = Recorder()
        let body = #"{ "chart": { "result": [ { "timestamp": [1788000000], "indicators": { "quote": [ { "open": [1.0], "high": [1.0], "low": [1.0], "close": [1.0] } ] } } ] } }"#
        let quotes = MarketQuotes(transport: { request in
            recorder.requests.append(request)
            return (Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        })

        _ = try await quotes.history(for: "AAPL", range: .fiveYears, interval: .minute)
        let url = try XCTUnwrap(recorder.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("interval=1wk"), "a minute bar over five years would be refused: \(url)")
        XCTAssertTrue(url.contains("range=5y"))
        let agent = try XCTUnwrap(recorder.requests.first?.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(agent.contains("Mozilla"), "Yahoo answers keyless only to a browser-ish agent")
    }

    func testACoinAsksTheSourceForDaysBecauseItHasNoIntervalParameter() async throws {
        final class Recorder: @unchecked Sendable {
            var requests: [URLRequest] = []
        }
        let recorder = Recorder()
        let quotes = MarketQuotes(transport: { request in
            recorder.requests.append(request)
            return (Data("[[1788004800000,1.0,2.0,0.5,1.5]]".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        })

        let candles = try await quotes.history(for: "btc", range: .month)
        XCTAssertEqual(candles.count, 1)
        let url = try XCTUnwrap(recorder.requests.first?.url?.absoluteString)
        XCTAssertTrue(url.contains("/coins/bitcoin/ohlc"), url)
        XCTAssertTrue(url.contains("days=30"), "the coin endpoint takes a day count, not an interval")
        XCTAssertFalse(url.contains("interval="), "sending one would be ignored, so it is not sent")
    }
}
