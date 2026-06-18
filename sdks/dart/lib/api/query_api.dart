//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;


class QueryApi {
  QueryApi([ApiClient? apiClient]) : apiClient = apiClient ?? defaultApiClient;

  final ApiClient apiClient;

  /// List registered engines + capabilities.
  ///
  /// Note: This method returns the HTTP [Response].
  Future<Response> queryEnginesWithHttpInfo({ Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/query/v1/engines';

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

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

  /// List registered engines + capabilities.
  Future<QueryEngines200Response?> queryEngines({ Future<void>? abortTrigger, }) async {
    final response = await queryEnginesWithHttpInfo(abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'QueryEngines200Response',) as QueryEngines200Response;
    
    }
    return null;
  }

  /// Run one engine-agnostic data operation against a mount.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [QueryRequest] queryRequest (required):
  Future<Response> queryExecuteWithHttpInfo(QueryRequest queryRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/query/v1/execute';

    // ignore: prefer_final_locals
    Object? postBody = queryRequest;

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

  /// Run one engine-agnostic data operation against a mount.
  ///
  /// Parameters:
  ///
  /// * [QueryRequest] queryRequest (required):
  Future<QueryResponse?> queryExecute(QueryRequest queryRequest, { Future<void>? abortTrigger, }) async {
    final response = await queryExecuteWithHttpInfo(queryRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'QueryResponse',) as QueryResponse;
    
    }
    return null;
  }

  /// Introspect a mount's tables + live engine capabilities.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] dbId (required):
  Future<Response> querySchemaWithHttpInfo(String dbId, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/query/v1/{dbId}/schema'
      .replaceAll('{dbId}', dbId);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

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

  /// Introspect a mount's tables + live engine capabilities.
  ///
  /// Parameters:
  ///
  /// * [String] dbId (required):
  Future<Map<String, Object>?> querySchema(String dbId, { Future<void>? abortTrigger, }) async {
    final response = await querySchemaWithHttpInfo(dbId, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return Map<String, Object>.from(await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'Map<String, Object>'),);

    }
    return null;
  }

  /// Apply ONE schema-DDL operation to a mount.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] dbId (required):
  ///
  /// * [Map<String, Object>] requestBody (required):
  Future<Response> querySchemaDdlWithHttpInfo(String dbId, Map<String, Object> requestBody, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/query/v1/{dbId}/schema/ddl'
      .replaceAll('{dbId}', dbId);

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

  /// Apply ONE schema-DDL operation to a mount.
  ///
  /// Parameters:
  ///
  /// * [String] dbId (required):
  ///
  /// * [Map<String, Object>] requestBody (required):
  Future<void> querySchemaDdl(String dbId, Map<String, Object> requestBody, { Future<void>? abortTrigger, }) async {
    final response = await querySchemaDdlWithHttpInfo(dbId, requestBody, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Single-mount atomic write batch (all-or-nothing).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [TxnRequest] txnRequest (required):
  Future<Response> queryTxnWithHttpInfo(TxnRequest txnRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/query/v1/txn';

    // ignore: prefer_final_locals
    Object? postBody = txnRequest;

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

  /// Single-mount atomic write batch (all-or-nothing).
  ///
  /// Parameters:
  ///
  /// * [TxnRequest] txnRequest (required):
  Future<TxnResponse?> queryTxn(TxnRequest txnRequest, { Future<void>? abortTrigger, }) async {
    final response = await queryTxnWithHttpInfo(txnRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'TxnResponse',) as TxnResponse;
    
    }
    return null;
  }
}
