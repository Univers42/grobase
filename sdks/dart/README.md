# grobase (Dart) — generated client *(experimental)*

A **generated Dart client** for the [Grobase](https://github.com/Univers42/grobase) BaaS public API,
produced by the [OpenAPI Generator](https://openapi-generator.tech) from the
`openapi/grobase-public.json` spec.

> **Status: experimental / not feature-complete.** This is auto-generated transport code, not a
> hand-crafted SDK, and has **no convenience facade**. It does **not** have feature parity with the
> first-class TypeScript/JavaScript SDK [`@mini-baas/js`](../sdk) (hand-written, Supabase-shaped).
> For production use today, prefer `@mini-baas/js`. This package is **not yet published to pub.dev** —
> depend on it from git or a local path.

- API version: 0.2.0
- Generator: OpenAPI Generator (Dart client)
- Requires: Dart 2.12+

## Install (from source)

Not on pub.dev yet. Add it from git in your `pubspec.yaml`:

```yaml
dependencies:
  grobase:
    git:
      url: https://github.com/Univers42/grobase.git
      path: sdk-dart
```

Or from a local checkout:

```yaml
dependencies:
  grobase:
    path: /path/to/grobase/sdk-dart
```

## Minimal usage

Every endpoint is relative to the gateway base URL (default `http://127.0.0.1:8002`) and authorized
with the `apiKey` security scheme (sent as the `apikey` header).

```dart
import 'package:grobase/api.dart';

Future<void> main() async {
  // Wire the apikey auth into an ApiClient.
  final auth = ApiKeyAuth('header', 'apikey')..apiKey = 'your-anon-or-service-key';
  final client = ApiClient(
    basePath: 'http://127.0.0.1:8002',
    authentication: auth,
  );

  final rest = RestApi(client);
  try {
    final rows = await rest.restSelect('todos', limit: 10); // GET /rest/v1/todos
    print(rows);
    await rest.restInsert('todos', {'title': 'from dart'});
  } catch (e) {
    print('API error: $e');
  }
}
```

Generated API classes: `AuthApi`, `RestApi`, `QueryApi`, `StorageApi`, `FunctionsApi`. Per-endpoint
docs are under [`doc/`](doc/).
