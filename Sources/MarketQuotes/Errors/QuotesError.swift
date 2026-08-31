//
//  QuotesError.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What can go wrong asking for a price.
public enum QuotesError: Error, LocalizedError, Sendable, Equatable {
    /// A symbol could not be turned into a request.
    case badURL(String)
    /// A source answered with an HTTP failure.
    case http(Int)
    /// A source is rate-limiting; retry after this many seconds if known.
    case rateLimited(retryAfter: Int?)
    /// A response did not have the documented shape.
    case malformed(String)
    /// No listing matched the symbol.
    case unknownSymbol(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let s): return "\(s) is not a symbol a request can be made from"
        case .http(let code): return "the source answered HTTP \(code)"
        case .rateLimited(let after):
            return "the source is rate-limiting" + (after.map { " (retry after \($0)s)" } ?? "")
        case .malformed(let what): return "unexpected response shape: \(what)"
        case .unknownSymbol(let s): return "no listing matches \"\(s)\""
        }
    }
}
