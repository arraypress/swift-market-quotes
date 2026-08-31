//
//  MarketQuotes.swift
//  MarketQuotes
//
//  Created by David Sherlock on 2026.
//
//  Prices without keys: CoinGecko for coins, Yahoo's chart metadata for
//  equities. Both are public endpoints that stay public because callers
//  behave — requests are batched where the API allows, 429s honour
//  Retry-After, and the transport and the waiting are injectable so the
//  whole client tests on recordings without a network or a clock.
//

import Foundation

/// A keyless client for coin and equity prices.
public struct MarketQuotes: Sendable {

    /// How requests are performed — injectable so tests run on recordings.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// How a retry waits — injectable so rate-limit tests cost no wall-clock.
    public typealias Sleeper = @Sendable (_ seconds: Int) async throws -> Void

    /// Sent to CoinGecko; Yahoo receives a browser string, which its edge
    /// requires of keyless callers.
    public static let defaultUserAgent = "swift-market-quotes/0.1 (+https://github.com/arraypress/swift-market-quotes)"

    private let userAgent: String
    private let transport: Transport
    private let sleeper: Sleeper

    /// A client.
    ///
    /// - Parameters:
    ///   - userAgent: Identify yourself to CoinGecko.
    ///   - transport: Leave `nil` for the shared URLSession.
    ///   - sleeper: How a 429 retry waits; leave `nil` for real sleeping.
    public init(userAgent: String = MarketQuotes.defaultUserAgent,
                transport: Transport? = nil, sleeper: Sleeper? = nil) {
        self.userAgent = userAgent
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw QuotesError.malformed("not an HTTP response")
            }
            return (data, http)
        }
        self.sleeper = sleeper ?? { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 1)) * 1_000_000_000)
        }
    }

    // MARK: - Quotes

    /// Prices for a mixed bag of symbols — coins and tickers together.
    ///
    /// Coins are priced in `currency` with one batched call; equities come
    /// back in their listing currency (Yahoo does not convert), one call
    /// each. Symbols that match nothing throw ``QuotesError/unknownSymbol(_:)``.
    public func quotes(for symbols: [String], currency: String = "usd",
                       prefer: SymbolResolver.Preference = .auto) async throws -> [Quote] {
        var coinIDBySymbol: [(symbol: String, id: String)] = []
        var equities: [String] = []
        for raw in symbols {
            switch SymbolResolver.classify(raw, prefer: prefer) {
            case .crypto(let id): coinIDBySymbol.append((raw.uppercased(), id))
            case .cryptoUnresolved(let symbol):
                let hits = try await search(symbol)
                let exact = hits.first { $0.symbol.lowercased() == symbol }
                guard let hit = exact ?? hits.first else {
                    throw QuotesError.unknownSymbol(raw)
                }
                coinIDBySymbol.append((hit.symbol, hit.id))
            case .equity(let symbol): equities.append(symbol)
            }
        }
        var out: [Quote] = []
        if !coinIDBySymbol.isEmpty {
            let priced = try await coinPrices(ids: coinIDBySymbol.map(\.id), currency: currency)
            for (symbol, id) in coinIDBySymbol {
                guard let entry = priced[id] else { throw QuotesError.unknownSymbol(symbol) }
                out.append(Quote(symbol: symbol, name: id.replacingOccurrences(of: "-", with: " ").capitalized,
                                 price: entry.price, changePercent: entry.change,
                                 currency: currency, marketCap: entry.cap, kind: .crypto))
            }
        }
        for symbol in equities {
            out.append(try await equityQuote(symbol))
        }
        return out
    }

    /// The crypto market-cap table, biggest first.
    public func top(limit: Int = 10, currency: String = "usd") async throws -> [CoinListing] {
        struct Row: Decodable {
            let id: String, symbol: String, name: String
            let current_price: Double, market_cap: Double
            let market_cap_rank: Int
            let price_change_percentage_24h: Double?
        }
        let data = try await perform(Endpoints.markets(currency: currency, limit: limit))
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw QuotesError.malformed("coins/markets")
        }
        return rows.map {
            CoinListing(rank: $0.market_cap_rank, id: $0.id, symbol: $0.symbol.uppercased(),
                        name: $0.name, price: $0.current_price, marketCap: $0.market_cap,
                        changePercent: $0.price_change_percentage_24h)
        }
    }

    /// Listings matching a text search, best first.
    public func search(_ text: String) async throws -> [SearchHit] {
        struct Response: Decodable {
            struct Coin: Decodable { let id: String, symbol: String, name: String; let market_cap_rank: Int? }
            let coins: [Coin]
        }
        let data = try await perform(Endpoints.search(text))
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw QuotesError.malformed("search")
        }
        return decoded.coins.map { SearchHit(id: $0.id, symbol: $0.symbol.uppercased(), name: $0.name, rank: $0.market_cap_rank) }
    }

    // MARK: - Sources

    struct CoinPrice { let price: Double; let change: Double?; let cap: Double? }

    /// One batched simple/price call, keyed by CoinGecko id.
    func coinPrices(ids: [String], currency: String) async throws -> [String: CoinPrice] {
        let data = try await perform(Endpoints.coinPrice(ids: ids, currency: currency))
        guard let raw = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else {
            throw QuotesError.malformed("simple/price")
        }
        var out: [String: CoinPrice] = [:]
        for (id, fields) in raw {
            guard let price = fields[currency] else { continue }
            out[id] = CoinPrice(price: price,
                                change: fields["\(currency)_24h_change"],
                                cap: fields["\(currency)_market_cap"])
        }
        return out
    }

    /// One equity via Yahoo's chart metadata. Listing currency only.
    func equityQuote(_ symbol: String) async throws -> Quote {
        struct Chart: Decodable {
            struct Outer: Decodable { let result: [Entry]?; }
            struct Entry: Decodable { let meta: Meta }
            struct Meta: Decodable {
                let currency: String?
                let symbol: String
                let regularMarketPrice: Double?
                let regularMarketChangePercent: Double?
                let chartPreviousClose: Double?
                let longName: String?
                let shortName: String?
            }
            let chart: Outer
        }
        guard let url = Endpoints.yahooChart(symbol: symbol) else { throw QuotesError.badURL(symbol) }
        // Yahoo's edge refuses non-browser agents for keyless callers — and
        // answers 404 for a symbol it has never heard of, which is an
        // unknown symbol, not an outage.
        let data: Data
        do {
            data = try await perform(url, userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
        } catch QuotesError.http(404) {
            throw QuotesError.unknownSymbol(symbol)
        }
        guard let decoded = try? JSONDecoder().decode(Chart.self, from: data),
              let meta = decoded.chart.result?.first?.meta else {
            throw QuotesError.unknownSymbol(symbol)
        }
        guard let price = meta.regularMarketPrice else { throw QuotesError.unknownSymbol(symbol) }
        let change = meta.regularMarketChangePercent
            ?? meta.chartPreviousClose.map { previous in (price - previous) / previous * 100 }
        return Quote(symbol: meta.symbol, name: meta.longName ?? meta.shortName ?? meta.symbol,
                     price: price, changePercent: change,
                     currency: (meta.currency ?? "USD").lowercased(), marketCap: nil, kind: .equity)
    }

    // MARK: - Plumbing

    /// GET with the User-Agent, retrying a 429 twice with Retry-After
    /// (capped at ten seconds) before surfacing it.
    func perform(_ url: URL, userAgent overrideAgent: String? = nil, retriesLeft: Int = 2) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(overrideAgent ?? userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 200...299:
            return data
        case 429:
            let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            guard retriesLeft > 0 else { throw QuotesError.rateLimited(retryAfter: after) }
            try await sleeper(min(after ?? 2, 10))
            return try await perform(url, userAgent: overrideAgent, retriesLeft: retriesLeft - 1)
        default:
            throw QuotesError.http(response.statusCode)
        }
    }
}
