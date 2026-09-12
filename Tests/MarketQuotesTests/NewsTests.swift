//
//  NewsTests.swift
//  MarketQuotesTests
//
//  Created by David Sherlock on 2026.
//
//  Stories about a symbol — and the trap that makes them worth checking.
//
//  Both fixtures are real responses captured live on 2026-09-12, including the one for a
//  symbol that does not exist. That one is the point of this file: it answers HTTP 200 with
//  five perfectly ordinary articles, and nothing inside it says they are unrelated.
//

import Foundation
import XCTest
@testable import MarketQuotes

final class NewsTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                         subdirectory: "Fixtures")))
    }

    private func client(_ name: String) throws -> MarketQuotes {
        let data = try fixture(name)
        return MarketQuotes(transport: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!)
        }, sleeper: { _ in })
    }

    // MARK: The endpoint

    func testTheSearchURLCarriesItsGrammar() throws {
        let url = try XCTUnwrap(Endpoints.yahooSearch(query: "AAPL", newsCount: 5))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!

        XCTAssertEqual(items.first { $0.name == "q" }?.value, "AAPL")
        XCTAssertEqual(items.first { $0.name == "newsCount" }?.value, "5")
        XCTAssertEqual(items.first { $0.name == "quotesCount" }?.value, "1",
                       "a quote is always asked for — it is how the symbol is validated")
    }

    /// The endpoint silently caps at ten; passing more through would promise a caller
    /// something the source will not give.
    func testNewsCountIsClampedToWhatTheSourceWillGive() throws {
        func count(_ asked: Int) throws -> String? {
            let url = try XCTUnwrap(Endpoints.yahooSearch(query: "AAPL", newsCount: asked))
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "newsCount" }?.value
        }
        XCTAssertEqual(try count(50), "10")
        XCTAssertEqual(try count(10), "10")
        XCTAssertEqual(try count(0), "1", "zero stories is not a request worth making")
        XCTAssertEqual(try count(-5), "1")
    }

    // MARK: Reading a story

    func testStoriesAreReadFromARealResponse() async throws {
        let stories = try await client("yahoo-search-aapl").news(for: "AAPL", limit: 5)

        XCTAssertFalse(stories.isEmpty)
        let first = try XCTUnwrap(stories.first)
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertFalse(first.publisher.isEmpty)
        XCTAssertNotNil(first.link)
        XCTAssertGreaterThan(first.published.timeIntervalSince1970, 1_600_000_000,
                             "the timestamp is unix seconds, not milliseconds")
        XCTAssertTrue(first.mentions("AAPL"))
    }

    func testAStoryMissingATitleIsDropped() {
        XCTAssertNil(MarketQuotes.headline(["uuid": "x", "publisher": "P"]))
        XCTAssertNil(MarketQuotes.headline(["title": "", "publisher": "P"]))
        XCTAssertNotNil(MarketQuotes.headline(["title": "Something happened"]))
    }

    func testAStoryMissingOptionalFieldsStillReads() throws {
        let story = try XCTUnwrap(MarketQuotes.headline(["title": "Bare"]))
        XCTAssertEqual(story.publisher, "unknown")
        XCTAssertNil(story.link)
        XCTAssertTrue(story.relatedTickers.isEmpty)
        XCTAssertEqual(story.id, "Bare", "the title stands in when there is no uuid")
    }

    func testRelatedTickersAreUppercasedAndMatchLoosely() throws {
        let story = try XCTUnwrap(MarketQuotes.headline([
            "title": "T", "relatedTickers": ["btc-usd", "nvda"]
        ]))
        XCTAssertEqual(story.relatedTickers, ["BTC-USD", "NVDA"])
        XCTAssertTrue(story.mentions("BTC-USD"))
        XCTAssertTrue(story.mentions("btc"), "asking for BTC should match a BTC-USD tag")
        XCTAssertTrue(story.mentions("NVDA"))
        XCTAssertFalse(story.mentions("AAPL"))
    }

    // MARK: The trap

    /// THE REASON THIS FEATURE NEEDED CARE. A symbol that does not exist answers HTTP 200
    /// with five ordinary articles. Without the quotes check a reader would be shown
    /// confident headlines under a symbol that was never real.
    func testAnUnknownSymbolIsRefusedEvenThoughStoriesCameBack() async throws {
        let raw = try JSONSerialization.jsonObject(with: fixture("yahoo-search-unknown"))
        let news = (raw as? [String: Any])?["news"] as? [[String: Any]] ?? []
        XCTAssertEqual(news.count, 5, "the fixture really does carry stories")

        do {
            _ = try await client("yahoo-search-unknown").news(for: "ZZZNOTATICKER")
            XCTFail("a symbol with no listing must not return stories")
        } catch let error as QuotesError {
            XCTAssertEqual(error, .unknownSymbol("ZZZNOTATICKER"))
        }
    }

    /// The second defence: the symbol is real, but the stories are about the wider market.
    func testUnrelatedStoriesAreFilteredOutByDefault() async throws {
        let payload = """
        { "quotes": [{"symbol": "AAPL"}],
          "news": [
            {"uuid":"1","title":"Apple thing","publisher":"P","providerPublishTime":1789211700,
             "relatedTickers":["AAPL"]},
            {"uuid":"2","title":"Unrelated market thing","publisher":"P",
             "providerPublishTime":1789211700,"relatedTickers":["^GSPC"]},
            {"uuid":"3","title":"Produce recall","publisher":"P","providerPublishTime":1789211700}
          ] }
        """
        let data = Data(payload.utf8)
        let quotes = MarketQuotes(transport: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!)
        }, sleeper: { _ in })

        let filtered = try await quotes.news(for: "AAPL")
        XCTAssertEqual(filtered.map(\.title), ["Apple thing"])

        let everything = try await quotes.news(for: "AAPL", relatedOnly: false)
        XCTAssertEqual(everything.count, 3, "the filter can be turned off deliberately")
    }

    func testAnEmptySymbolIsRefusedBeforeAnyRequest() async throws {
        // A class rather than a captured var: the transport closure is Sendable, so a
        // mutable capture will not compile — and a lock here would be testing the test.
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let quotes = MarketQuotes(transport: { request in
            counter.calls += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200,
                                            httpVersion: nil, headerFields: nil)!)
        }, sleeper: { _ in })

        do {
            _ = try await quotes.news(for: "   ")
            XCTFail("an empty symbol is not a request worth making")
        } catch {
            XCTAssertEqual(counter.calls, 0, "nothing should reach the network")
        }
    }

    func testAMalformedResponseIsReportedNotCrashed() async throws {
        let data = Data("not json at all".utf8)
        let quotes = MarketQuotes(transport: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!)
        }, sleeper: { _ in })

        do {
            _ = try await quotes.news(for: "AAPL")
            XCTFail("expected a malformed error")
        } catch let error as QuotesError {
            guard case .malformed = error else { return XCTFail("got \(error)") }
        }
    }
}
