# grobase (Python) — generated client *(experimental)*

A **generated Python client** for the [Grobase](https://github.com/Univers42/grobase) BaaS public
API, produced by the [OpenAPI Generator](https://openapi-generator.tech) from the
`openapi/grobase-public.json` spec.

> **Status: experimental / not feature-complete.** This is auto-generated transport code, not a
> hand-crafted SDK. It does **not** have feature parity with the first-class TypeScript/JavaScript
> SDK [`@mini-baas/js`](../sdk) (which is hand-written and Supabase-shaped). For production use today,
> prefer `@mini-baas/js`. This package is **not yet published to PyPI** — install from source.
>
> A small hand-written convenience facade (`grobase.client.Client`) is included as the reference
> pattern for a friendlier surface — see [Convenience facade](#convenience-facade) below.

- API version: 0.2.0
- Package version: 0.2.0
- Generator: OpenAPI Generator (Python client)

## Requirements

Python 3.10+

## Install (from source)

Not on PyPI yet. Install directly from the repo subdirectory:

```sh
pip install "git+https://github.com/Univers42/grobase.git#subdirectory=sdk-python"
```

Or, from a local checkout of this directory:

```sh
pip install -e .
```

## Convenience facade

The hand-written `grobase.client.Client` wraps the generated APIs with a small, Supabase-shaped
surface (`Client(base_url, api_key)` + `.auth.sign_in()/sign_up()` + `.from_(table).select()/insert()/delete()`).
This is the **reference pattern** for the polyglot SDKs; it is intentionally minimal and experimental.

```python
from grobase.client import Client

baas = Client("http://127.0.0.1:8002", api_key="your-anon-or-service-key")

# Auth: exchange email + password for a session
session = baas.auth.sign_in("user@example.com", "secret")
print(session.access_token)

# CRUD against /rest/v1
rows = baas.from_("todos").select("*", limit=10)
baas.from_("todos").insert({"title": "ship the SDK", "done": False})
```

For anything beyond auth + basic CRUD, drop down to the generated API classes (below).

## Minimal usage (generated client directly)

Every endpoint is relative to the gateway base URL (default `http://127.0.0.1:8002`) and authorized
with the `apiKey` security scheme (sent as the `apikey` header).

```python
import grobase
from grobase.rest import ApiException

config = grobase.Configuration(host="http://127.0.0.1:8002")
config.api_key["apiKey"] = "your-anon-or-service-key"

with grobase.ApiClient(config) as api_client:
    rest = grobase.RestApi(api_client)
    try:
        rows = rest.rest_select(resource="todos", limit=10)  # GET /rest/v1/todos
        print(rows)
        rest.rest_insert(resource="todos", request_body={"title": "from python"})
    except ApiException as e:
        print("API error:", e)
```

Generated API classes: `AuthApi`, `RestApi`, `QueryApi`, `StorageApi`, `FunctionsApi`. Per-endpoint
docs are under [`docs/`](docs/).

## Tests

```sh
pytest
```
