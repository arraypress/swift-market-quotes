//
//  Headline.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//
//  One news story about a listing.
//

import Foundation

/// A news story, as Yahoo's search endpoint reports it.
public struct Headline: Codable, Sendable, Equatable {

    /// The story's stable id, so the same story is recognisable across calls.
    public let id: String

    /// The headline.
    public let title: String

    /// Who published it.
    public let publisher: String

    /// When it was published.
    public let published: Date

    /// A link to the story.
    public let link: URL?

    /// Tickers the publisher tagged the story with, uppercase.
    ///
    /// The field that makes a story checkable rather than merely plausible: a story about
    /// Apple carries `AAPL` here. See ``MarketQuotes/news(for:limit:relatedOnly:)`` for why
    /// that matters more than it sounds.
    public let relatedTickers: [String]

    /// Whether this story is tagged with the symbol it was asked for.
    ///
    /// - Parameter symbol: the symbol requested, in any case.
    public func mentions(_ symbol: String) -> Bool {
        let wanted = symbol.uppercased()
        return relatedTickers.contains(wanted)
            // "BTC-USD" is tagged as "BTC-USD", but a caller may reasonably ask for "BTC".
            || relatedTickers.contains { $0.split(separator: "-").first.map(String.init) == wanted }
    }

    public init(id: String, title: String, publisher: String, published: Date,
                link: URL?, relatedTickers: [String]) {
        self.id = id
        self.title = title
        self.publisher = publisher
        self.published = published
        self.link = link
        self.relatedTickers = relatedTickers
    }
}
