//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;


class FunctionsApi {
  FunctionsApi([ApiClient? apiClient]) : apiClient = apiClient ?? defaultApiClient;

  final ApiClient apiClient;

  /// Delete a deployed function.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  Future<Response> functionDeleteWithHttpInfo(String name, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/functions/v1/{name}'
      .replaceAll('{name}', name);

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

  /// Delete a deployed function.
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  Future<void> functionDelete(String name, { Future<void>? abortTrigger, }) async {
    final response = await functionDeleteWithHttpInfo(name, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Get a deployed function's source.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  Future<Response> functionGetWithHttpInfo(String name, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/functions/v1/{name}'
      .replaceAll('{name}', name);

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

  /// Get a deployed function's source.
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  Future<FunctionGet200Response?> functionGet(String name, { Future<void>? abortTrigger, }) async {
    final response = await functionGetWithHttpInfo(name, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'FunctionGet200Response',) as FunctionGet200Response;
    
    }
    return null;
  }

  /// Invoke a deployed edge function.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  ///
  /// * [Map<String, Object>] requestBody:
  Future<Response> functionInvokeWithHttpInfo(String name, { Map<String, Object>? requestBody, Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/functions/v1/{name}/invoke'
      .replaceAll('{name}', name);

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

  /// Invoke a deployed edge function.
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  ///
  /// * [Map<String, Object>] requestBody:
  Future<void> functionInvoke(String name, { Map<String, Object>? requestBody, Future<void>? abortTrigger, }) async {
    final response = await functionInvokeWithHttpInfo(name, requestBody: requestBody, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }
}
