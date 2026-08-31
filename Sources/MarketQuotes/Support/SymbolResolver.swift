//
//  SymbolResolver.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//
//  Deciding what a typed symbol means. `btc` is a coin and `AAPL` is a
//  stock, and nobody wants to say which — the resolver knows the major
//  coins by symbol, treats anything else as an equity unless told
//  otherwise, and stays pure so the decision is testable on its own.
//

import Foundation

/// Classifies typed symbols into the market that prices them.
public enum SymbolResolver {

    /// A caller's override of the automatic classification.
    public enum Preference: String, Sendable {
        /// Coins by the symbol table, everything else an equity.
        case auto
        /// Force crypto; unknown symbols resolve via text search.
        case crypto
        /// Force equity.
        case equity
    }

    /// What a symbol turned out to be.
    public enum Kind: Sendable, Equatable {
        /// A coin, by CoinGecko id.
        case crypto(id: String)
        /// A coin whose id must be found by search first.
        case cryptoUnresolved(symbol: String)
        /// A stock/ETF ticker.
        case equity(symbol: String)
    }

    /// The major coins by symbol — the ones people type without thinking.
    /// Everything else resolves through search when crypto is forced.
    static let coinIDs: [String: String] = [
        "btc": "bitcoin", "eth": "ethereum", "sol": "solana", "xrp": "ripple",
        "ada": "cardano", "doge": "dogecoin", "dot": "polkadot", "ltc": "litecoin",
        "bnb": "binancecoin", "usdt": "tether", "usdc": "usd-coin",
        "avax": "avalanche-2", "link": "chainlink", "matic": "matic-network",
        "ton": "the-open-network", "trx": "tron", "xlm": "stellar", "xmr": "monero",
    ]

    /// One symbol's market.
    public static func classify(_ raw: String, prefer: Preference = .auto) -> Kind {
        let lower = raw.lowercased()
        switch prefer {
        case .equity:
            return .equity(symbol: raw.uppercased())
        case .crypto:
            if let id = coinIDs[lower] { return .crypto(id: id) }
            // A CoinGecko id typed directly — `bitcoin`, `usd-coin` — is one already.
            if lower.count > 5 || lower.contains("-") { return .crypto(id: lower) }
            return .cryptoUnresolved(symbol: lower)
        case .auto:
            if let id = coinIDs[lower] { return .crypto(id: id) }
            if lower.contains("-") { return .crypto(id: lower) }
            return .equity(symbol: raw.uppercased())
        }
    }
}
