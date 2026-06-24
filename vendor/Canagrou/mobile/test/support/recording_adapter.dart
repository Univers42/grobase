import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:camagru_mobile/config/api_config.dart';

/// A captured outbound request: the bits the tests assert on.
class CapturedRequest {
  final String method;
  final String path;
  final Map<String, dynamic> headers;
  final Map<String, dynamic>? queryParameters;
  final dynamic body;

  CapturedRequest({
    required this.method,
    required this.path,
    required this.headers,
    required this.queryParameters,
    required this.body,
  });

  /// The request body decoded as a JSON map (for `/query` op assertions).
  Map<String, dynamic> get jsonBody {
    if (body is Map<String, dynamic>) return body as Map<String, dynamic>;
    if (body is String) {
      return jsonDecode(body as String) as Map<String, dynamic>;
    }
    return const {};
  }
}

/// A canned reply keyed to a path predicate.
class _Route {
  final bool Function(RequestOptions) match;
  final int statusCode;
  final dynamic data;
  _Route(this.match, this.statusCode, this.data);
}

/// A Dio [HttpClientAdapter] that records every request and replies with
/// pre-registered canned responses — no network, no `dart:io`. Lets the tests
/// assert exact `/query` op bodies and headers, which a pure matcher can't.
class RecordingAdapter implements HttpClientAdapter {
  final List<CapturedRequest> requests = [];
  final List<_Route> _routes = [];

  /// Registers a JSON reply for requests whose path contains [pathContains].
  void onPath(String pathContains, {int status = 200, Object? data}) {
    _routes.add(_Route(
      (o) => o.path.contains(pathContains),
      status,
      data ?? const {},
    ));
  }

  /// Registers a reply matched by a custom [predicate] (first match wins).
  void on(bool Function(RequestOptions) predicate,
      {int status = 200, Object? data}) {
    _routes.add(_Route(predicate, status, data ?? const {}));
  }

  CapturedRequest get last => requests.last;

  /// Returns the first captured request whose path contains [pathContains].
  CapturedRequest firstWithPath(String pathContains) =>
      requests.firstWhere((r) => r.path.contains(pathContains));

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(CapturedRequest(
      method: options.method,
      path: options.path,
      headers: Map<String, dynamic>.from(options.headers),
      queryParameters: Map<String, dynamic>.from(options.queryParameters),
      body: await _readBody(options, requestStream),
    ));
    final route = _routes.firstWhere(
      (r) => r.match(options),
      orElse: () => _Route((_) => true, 200, const {}),
    );
    return ResponseBody.fromString(
      jsonEncode(route.data),
      route.statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  Future<dynamic> _readBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (options.data is Map) return options.data;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      final bytes = chunks.expand((c) => c).toList();
      return utf8.decode(bytes);
    }
    if (options.data is String) return options.data;
    return null;
  }

  @override
  void close({bool force = false}) {}
}

/// A [BaasConfig] with fixed test values so header/body assertions are stable.
BaasConfig testConfig() => const BaasConfig(
      url: 'http://test.local',
      anonKey: 'anon-key',
      apiKey: 'mbk_test_key',
      tenantId: 'canagrou',
      dbId: 'db-uuid',
      storageBucket: 'post-images',
      storageToken: 'storage-token',
      realtimeToken: 'realtime-token',
    );
