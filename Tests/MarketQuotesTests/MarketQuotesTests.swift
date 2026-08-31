//
//  MarketQuotesTests.swift
//  MarketQuotesTests
//
//  Created by David Sherlock on 2026.
//
//  Recordings, not networks: every fixture is a real response captured
//  live on 2026-08-31. The URL grammar, the resolver and the retry are
//  tested as the pure things they are.
//

import Foundation
import XCTest
@testable import MarketQuotes

final class MarketQuotesTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    private func client(_ handler: @escaping @Sendable (URLRequest) -> (Data, Int)) -> MarketQuotes {
        MarketQuotes(transport: { request in
            let (data, code) = handler(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }, sleeper: { _ in })
    }

    func testEndpointsCarryTheDocumentedGrammar() {
        let price = Endpoints.coinPrice(ids: ["bitcoin", "ethereum"], currency: "eur")
        let items = URLComponents(url: price, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "ids" }?.value, "bitcoin,ethereum")
        XCTAssertEqual(items.first { $0.name == "vs_currencies" }?.value, "eur")
        XCTAssertEqual(items.first { $0.name == "include_24hr_change" }?.value, "true")

        let markets = Endpoints.markets(currency: "usd", limit: 999)
        XCTAssertTrue(markets.query!.contains("per_page=250"), "the page cap is the API's, clamped: \(markets)")

        XCTAssertTrue(Endpoints.yahooChart(symbol: "AAPL")!.absoluteString.contains("/chart/AAPL?"))
    }

    func testResolverKnowsCoinsTickersAndOverrides() {
        XCTAssertEqual(SymbolResolver.classify("btc"), .crypto(id: "bitcoin"))
        XCTAssertEqual(SymbolResolver.classify("BTC"), .crypto(id: "bitcoin"))
        XCTAssertEqual(SymbolResolver.classify("AAPL"), .equity(symbol: "AAPL"))
        XCTAssertEqual(SymbolResolver.classify("usd-coin"), .crypto(id: "usd-coin"))
        XCTAssertEqual(SymbolResolver.classify("aapl", prefer: .crypto), .cryptoUnresolved(symbol: "aapl"))
        XCTAssertEqual(SymbolResolver.classify("btc", prefer: .equity), .equity(symbol: "BTC"))
        XCTAssertEqual(SymbolResolver.classify("bitcoin", prefer: .crypto), .crypto(id: "bitcoin"))
    }

    func testCoinQuotesDecodeTheRecordedPrices() async throws {
        let data = try fixture("cg-price")
        let quotes = try await client { _ in (data, 200) }.quotes(for: ["btc", "eth"])
        XCTAssertEqual(quotes.count, 2)
        let btc = try XCTUnwrap(quotes.first { $0.symbol == "BTC" })
        XCTAssertEqual(btc.price, 77834, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(btc.changePercent), -1.1175, accuracy: 0.001)
        XCTAssertEqual(btc.kind, .crypto)
        XCTAssertEqual(btc.currency, "usd")
        XCTAssertNotNil(btc.marketCap)
    }

    func testEquityQuoteDecodesYahooMetadata() async throws {
        let data = try fixture("yahoo")
        let quote = try await client { _ in (data, 200) }.quotes(for: ["AAPL"]).first
        let aapl = try XCTUnwrap(quote)
        XCTAssertEqual(aapl.symbol, "AAPL")
        XCTAssertEqual(aapl.price, 319.7, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(aapl.changePercent), 1.628, accuracy: 0.001)
        XCTAssertEqual(aapl.currency, "usd")
        XCTAssertEqual(aapl.kind, .equity)
    }

    func testTopDecodesRankedListings() async throws {
        let data = try fixture("cg-markets")
        let rows = try await client { _ in (data, 200) }.top(limit: 5)
        XCTAssertEqual(rows.first?.id, "bitcoin")
        XCTAssertEqual(rows.first?.rank, 1)
        XCTAssertEqual(rows.first?.symbol, "BTC")
        XCTAssertEqual(rows.map(\.rank), rows.map(\.rank).sorted(), "biggest first")
    }

    func testSearchDecodesHits() async throws {
        let data = try fixture("cg-search")
        let hits = try await client { _ in (data, 200) }.search("solana")
        XCTAssertEqual(hits.first?.id, "solana")
        XCTAssertEqual(hits.first?.symbol, "SOL")
        XCTAssertEqual(hits.first?.rank, 7)
    }

    func testRateLimitRetriesOnInjectedClockThenSurfaces() async throws {
        final class Trace: @unchecked Sendable {
            let lock = NSLock(); var waits: [Int] = []
            func slept(_ s: Int) { lock.lock(); waits.append(s); lock.unlock() }
        }
        let trace = Trace()
        let limited = MarketQuotes(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                     headerFields: ["Retry-After": "3"])!)
        }, sleeper: { s in trace.slept(s) })
        do {
            _ = try await limited.top()
            XCTFail("three 429s must surface as rateLimited")
        } catch let error as QuotesError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 3))
        }
        XCTAssertEqual(trace.waits, [3, 3], "two retries honouring Retry-After, no real sleeping")
    }

    func testUnknownSymbolIsNamedNotMangled() async throws {
        let data = Data("{\"chart\":{\"result\":null}}".utf8)
        do {
            _ = try await client { _ in (data, 200) }.quotes(for: ["ZZZZFAKE"])
            XCTFail("an unknown ticker must throw")
        } catch let error as QuotesError {
            XCTAssertEqual(error, .unknownSymbol("ZZZZFAKE"))
        }
    }

    func testYahooFourOhFourReadsAsUnknownNotOutage() async throws {
        // Yahoo answers 404 for a symbol it has never heard of. That is an
        // unknown symbol (exit 1 at the CLI), not an upstream failure (5).
        do {
            _ = try await client { _ in (Data(), 404) }.quotes(for: ["ZZZZFAKE"])
            XCTFail("a 404 must throw")
        } catch let error as QuotesError {
            XCTAssertEqual(error, .unknownSymbol("ZZZZFAKE"))
        }
    }
}
