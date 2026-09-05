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

    /// Yahoo's v8 endpoint answers keyless only when the request looks like a
    /// browser. Named once so the quote and history paths cannot drift.
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

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

    // MARK: - History

    /// Price history for one symbol — a coin or a ticker.
    ///
    /// Routed the same way as a live quote: a coin goes to CoinGecko's OHLC
    /// series, a ticker to the Yahoo chart. The two sources differ in what
    /// they can give you, and the difference is not hidden:
    ///
    /// - a coin's bars carry **no volume**, because the endpoint sends none;
    /// - a coin's granularity is **chosen by the source** from the day count,
    ///   so `interval` is ignored for coins rather than quietly disobeyed.
    ///
    /// - Parameters:
    ///   - symbol: `btc`, `bitcoin` or `AAPL`.
    ///   - range: How far back.
    ///   - interval: Bar width. Equities only; clamped when finer than the
    ///     range allows, because the source rejects such a request outright.
    ///   - currency: Coins only — equities come back in their listing currency.
    public func history(for symbol: String,
                        range: HistoryRange = .month,
                        interval: HistoryInterval = .day,
                        currency: String = "usd",
                        prefer: SymbolResolver.Preference = .auto) async throws -> [Candle] {
        switch SymbolResolver.classify(symbol, prefer: prefer) {
        case .crypto(let id):
            return try await coinHistory(id: id, currency: currency, range: range)
        case .cryptoUnresolved(let name):
            let hits = try await search(name)
            let exact = hits.first { $0.symbol.lowercased() == name }
            guard let hit = exact ?? hits.first else { throw QuotesError.unknownSymbol(symbol) }
            return try await coinHistory(id: hit.id, currency: currency, range: range)
        case .equity(let ticker):
            return try await equityHistory(ticker, range: range, interval: interval)
        }
    }

    /// Yahoo's chart series for a ticker.
    private func equityHistory(_ symbol: String, range: HistoryRange,
                               interval: HistoryInterval) async throws -> [Candle] {
        // A minute bar over five years is not a request Yahoo answers, so the
        // interval is widened to the finest the range allows rather than sent
        // and rejected.
        let effective = interval.isTooFine(for: range)
            ? HistoryInterval.finestAllowed(for: range)
            : interval
        guard let url = Endpoints.yahooHistory(symbol: symbol, range: range, interval: effective) else {
            throw QuotesError.badURL(symbol)
        }
        // The same browser-ish User-Agent the live quote needs: Yahoo's v8
        // endpoint answers keyless only when the request looks like a browser.
        let data = try await perform(url, userAgent: MarketQuotes.browserUserAgent)
        let candles = try Series.yahoo(data)
        guard !candles.isEmpty else { throw QuotesError.unknownSymbol(symbol) }
        return candles
    }

    /// CoinGecko's OHLC series for a coin id.
    private func coinHistory(id: String, currency: String, range: HistoryRange) async throws -> [Candle] {
        guard let url = Endpoints.coinHistory(id: id, currency: currency, days: range.approximateDays) else {
            throw QuotesError.badURL(id)
        }
        let data = try await perform(url)
        return try Series.coinGecko(data)
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
            data = try await perform(url, userAgent: MarketQuotes.browserUserAgent)
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
