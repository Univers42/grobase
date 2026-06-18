//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;


class RestApi {
  RestApi([ApiClient? apiClient]) : apiClient = apiClient ?? defaultApiClient;

  final ApiClient apiClient;

  /// Delete rows matching the filter.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  Future<Response> restDeleteWithHttpInfo(String resource, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/rest/v1/{resource}'
      .replaceAll('{resource}', resource);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'DELETE',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Delete rows matching the filter.
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  Future<void> restDelete(String resource, { Future<void>? abortTrigger, }) async {
    final response = await restDeleteWithHttpInfo(resource, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Insert one or many rows.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  ///
  /// * [Map<String, Object>] requestBody (required):
  Future<Response> restInsertWithHttpInfo(String resource, Map<String, Object> requestBody, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/rest/v1/{resource}'
      .replaceAll('{resource}', resource);

    // ignore: prefer_final_locals
    Object? postBody = requestBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Insert one or many rows.
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  ///
  /// * [Map<String, Object>] requestBody (required):
  Future<void> restInsert(String resource, Map<String, Object> requestBody, { Future<void>? abortTrigger, }) async {
    final response = await restInsertWithHttpInfo(resource, requestBody, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Call a Postgres stored function (PostgREST RPC).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] fn (required):
  ///
  /// * [Map<String, Object>] requestBody:
  Future<Response> restRpcWithHttpInfo(String fn, { Map<String, Object>? requestBody, Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/rest/v1/rpc/{fn}'
      .replaceAll('{fn}', fn);

    // ignore: prefer_final_locals
    Object? postBody = requestBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Call a Postgres stored function (PostgREST RPC).
  ///
  /// Parameters:
  ///
  /// * [String] fn (required):
  ///
  /// * [Map<String, Object>] requestBody:
  Future<void> restRpc(String fn, { Map<String, Object>? requestBody, Future<void>? abortTrigger, }) async {
    final response = await restRpcWithHttpInfo(fn, requestBody: requestBody, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Select rows (PostgREST filters via query params).
  ///
  /// Filters are PostgREST `column=op.value` query params (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`), plus `select`, `order`, `limit`, `offset`, and `or`. Send `Accept: application/vnd.pgrst.object+json` for `.single()`.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  ///
  /// * [String] select:
  ///
  /// * [String] order:
  ///
  /// * [int] limit:
  ///
  /// * [int] offset:
  Future<Response> restSelectWithHttpInfo(String resource, { String? select, String? order, int? limit, int? offset, Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/rest/v1/{resource}'
      .replaceAll('{resource}', resource);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    if (select != null) {
      queryParams.addAll(_queryParams('', 'select', select));
    }
    if (order != null) {
      queryParams.addAll(_queryParams('', 'order', order));
    }
    if (limit != null) {
      queryParams.addAll(_queryParams('', 'limit', limit));
    }
    if (offset != null) {
      queryParams.addAll(_queryParams('', 'offset', offset));
    }

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'GET',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Select rows (PostgREST filters via query params).
  ///
  /// Filters are PostgREST `column=op.value` query params (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`), plus `select`, `order`, `limit`, `offset`, and `or`. Send `Accept: application/vnd.pgrst.object+json` for `.single()`.
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  ///
  /// * [String] select:
  ///
  /// * [String] order:
  ///
  /// * [int] limit:
  ///
  /// * [int] offset:
  Future<List<Object>?> restSelect(String resource, { String? select, String? order, int? limit, int? offset, Future<void>? abortTrigger, }) async {
    final response = await restSelectWithHttpInfo(resource, select: select, order: order, limit: limit, offset: offset, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      final responseBody = await _decodeBodyBytes(response);
      return (await apiClient.deserializeAsync(responseBody, 'List<Object>') as List)
        .cast<Object>()
        .toList(growable: false);

    }
    return null;
  }

  /// Update rows matching the filter.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  ///
  /// * [Map<String, Object>] requestBody (required):
  Future<Response> restUpdateWithHttpInfo(String resource, Map<String, Object> requestBody, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/rest/v1/{resource}'
      .replaceAll('{resource}', resource);

    // ignore: prefer_final_locals
    Object? postBody = requestBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'PATCH',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Update rows matching the filter.
  ///
  /// Parameters:
  ///
  /// * [String] resource (required):
  ///   Table or view name.
  ///
  /// * [Map<String, Object>] requestBody (required):
  Future<void> restUpdate(String resource, Map<String, Object> requestBody, { Future<void>? abortTrigger, }) async {
    final response = await restUpdateWithHttpInfo(resource, requestBody, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }
}
