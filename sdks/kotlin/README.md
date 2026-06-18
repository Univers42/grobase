# grobase (Kotlin) — generated client *(experimental)*

A **generated Kotlin client** for the [Grobase](https://github.com/Univers42/grobase) BaaS public
API, produced by the [OpenAPI Generator](https://openapi-generator.tech) from the
`openapi/grobase-public.json` spec.

> **Status: experimental / not feature-complete.** This is auto-generated transport code, not a
> hand-crafted SDK, and has **no convenience facade**. It does **not** have feature parity with the
> first-class TypeScript/JavaScript SDK [`@mini-baas/js`](../sdk) (hand-written, Supabase-shaped).
> For production use today, prefer `@mini-baas/js`. This package is **not yet published to a Maven
> repository** — build it from source.

- API version: 0.2.0
- Generator: OpenAPI Generator (Kotlin client)
- Requires: Kotlin 2.x, Gradle 8.x

## Build (from source)

Not published to Maven yet. Build the library locally:

```sh
./gradlew check assemble
```

Then depend on the produced artifact (under `build/libs/`) from your project.

## Minimal usage

Every endpoint is relative to the gateway base URL (default `http://127.0.0.1:8002`) and authorized
with the `apiKey` security scheme (sent as the `apikey` header). The apikey is configured once on the
static `ApiClient.apiKey` map.

```kotlin
import grobase.apis.RestApi
import grobase.infrastructure.ApiClient

fun main() {
    // Authorize: set the apikey header for all requests.
    ApiClient.apiKey["apikey"] = "your-anon-or-service-key"

    // Default base path is http://127.0.0.1:8002 (override via the constructor
    // or the `grobase.baseUrl` system property).
    val rest = RestApi(basePath = "http://127.0.0.1:8002")

    val rows = rest.restSelect(resource = "todos", limit = 10) // GET /rest/v1/todos
    println(rows)

    rest.restInsert(resource = "todos", requestBody = mapOf("title" to "from kotlin"))
}
```

Generated API classes: `AuthApi`, `RestApi`, `QueryApi`, `StorageApi`, `FunctionsApi`. Per-endpoint
docs are under [`docs/`](docs/).
