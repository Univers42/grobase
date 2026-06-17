# Grobase (Swift) — generated client *(experimental)*

A **generated Swift 5 client** for the [Grobase](https://github.com/Univers42/grobase) BaaS public
API, produced by the [OpenAPI Generator](https://openapi-generator.tech) from the
`openapi/grobase-public.json` spec.

> **Status: experimental / not feature-complete.** This is auto-generated transport code, not a
> hand-crafted SDK, and has **no convenience facade**. It does **not** have feature parity with the
> first-class TypeScript/JavaScript SDK [`@mini-baas/js`](../sdk) (hand-written, Supabase-shaped).
> For production use today, prefer `@mini-baas/js`. This package is **not yet published** to a
> registry / CocoaPods trunk — depend on it from source.

- API version: 0.2.0
- Generator: OpenAPI Generator (Swift 5 client)

## Install (from source)

Not published yet. Add it as a local Swift package, or via CocoaPods/Carthage pointing at this
checkout. With Swift Package Manager, reference the package directory in your `Package.swift`
dependencies, or use the bundled `Package.swift`.

## Minimal usage

Every endpoint is relative to the gateway base URL (default `http://127.0.0.1:8002`) and authorized
with the `apiKey` security scheme (sent as the `apikey` header). Configure both once on the static
`GrobaseAPI` type; the API methods are `async`/`throws`.

```swift
import Grobase

// Point at your gateway and set the apikey header for all requests.
GrobaseAPI.basePath = "http://127.0.0.1:8002"
GrobaseAPI.customHeaders["apikey"] = "your-anon-or-service-key"

do {
    // GET /rest/v1/todos
    let rows = try await RestAPI.restSelect(resource: "todos", limit: 10)
    print(rows)

    // POST /rest/v1/todos
    try await RestAPI.restInsert(resource: "todos", requestBody: ["title": AnyCodable("from swift")])
} catch {
    print("API error: \(error)")
}
```

Generated API classes: `AuthAPI`, `RestAPI`, `QueryAPI`, `StorageAPI`, `FunctionsAPI`. Per-endpoint
docs are under [`docs/`](docs/).
