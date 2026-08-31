# swift-market-quotes

Coin and equity prices for Swift, with no API key.

```swift
import MarketQuotes

let quotes = try await MarketQuotes().quotes(for: ["btc", "eth", "AAPL"])
// BTC 78,010 USD −0.85% · ETH 2,452.27 USD · AAPL 319.70 USD +1.63%
```

## Two sources, one call

| | Coins | Equities |
|---|---|---|
| Source | CoinGecko `/simple/price`, `/coins/markets`, `/search` | Yahoo Finance v8 chart metadata |
| Batching | one request for any number of ids | one request per ticker |
| Currency | `usd`, `eur`, `gbp` — converted by the source | **listing currency only** — Yahoo does not convert |
| Standing | documented public API, ~10–30 req/min free | unofficial; works keyless with a browser User-Agent |

Symbols sort themselves: the major coin symbols (`btc`, `eth`, `sol`, …) are known outright, a
CoinGecko id (`bitcoin`, `usd-coin`) is taken as one, and anything else is treated as a ticker.
`SymbolResolver.Preference` (`.crypto` / `.equity`) settles arguments like COIN the ticker versus
coin the search term.

The Yahoo dependency is scoped honestly: the v8 chart endpoint is unofficial and could change or
close. It answers keyless today provided the request carries a browser-ish User-Agent — verified
live 2026-08-31 — and a 404 from it is surfaced as `unknownSymbol`, not an outage.

## API

```swift
let client = MarketQuotes()
try await client.quotes(for: ["btc", "aapl"], currency: "usd")   // [Quote]
try await client.top(limit: 20, currency: "eur")                 // [CoinListing], rank order
try await client.search("solana")                                // [SearchHit] — ids for quotes(for:)
```

## Built to be tested without a network

The transport and the retry clock are both injectable:

```swift
MarketQuotes(transport: { request in (fixtureData, response200) },
             sleeper: { seconds in /* recorded, not slept */ })
```

Every test in the suite runs on responses recorded live — decoding, URL grammar, symbol
resolution and the 429 path (two retries honouring `Retry-After`, capped at 10 s) are all
asserted in milliseconds with zero requests.

## Requirements

- macOS 14+ / iOS 16+, Swift 6

## License

MIT — see [LICENSE](LICENSE).
