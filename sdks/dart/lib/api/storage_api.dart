//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;


class StorageApi {
  StorageApi([ApiClient? apiClient]) : apiClient = apiClient ?? defaultApiClient;

  final ApiClient apiClient;

  /// Create a bucket.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  Future<Response> storageCreateBucketWithHttpInfo(String name,) async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/bucket/{name}'
      .replaceAll('{name}', name);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
    );
  }

  /// Create a bucket.
  ///
  /// Parameters:
  ///
  /// * [String] name (required):
  Future<StorageCreateBucket200Response?> storageCreateBucket(String name,) async {
    final response = await storageCreateBucketWithHttpInfo(name,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'StorageCreateBucket200Response',) as StorageCreateBucket200Response;
    
    }
    return null;
  }

  /// Delete an object.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  Future<Response> storageDeleteWithHttpInfo(String bucket, String key,) async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/object/{bucket}/{key}'
      .replaceAll('{bucket}', bucket)
      .replaceAll('{key}', key);

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
    );
  }

  /// Delete an object.
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  Future<void> storageDelete(String bucket, String key,) async {
    final response = await storageDeleteWithHttpInfo(bucket, key,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Download object bytes (owner-scoped).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  Future<Response> storageDownloadWithHttpInfo(String bucket, String key,) async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/object/{bucket}/{key}'
      .replaceAll('{bucket}', bucket)
      .replaceAll('{key}', key);

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
    );
  }

  /// Download object bytes (owner-scoped).
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  Future<MultipartFile?> storageDownload(String bucket, String key,) async {
    final response = await storageDownloadWithHttpInfo(bucket, key,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'MultipartFile',) as MultipartFile;
    
    }
    return null;
  }

  /// List objects under a prefix (owner-scoped).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] prefix:
  Future<Response> storageListWithHttpInfo(String bucket, { String? prefix, }) async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/list/{bucket}'
      .replaceAll('{bucket}', bucket);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    if (prefix != null) {
      queryParams.addAll(_queryParams('', 'prefix', prefix));
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
    );
  }

  /// List objects under a prefix (owner-scoped).
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] prefix:
  Future<StorageList200Response?> storageList(String bucket, { String? prefix, }) async {
    final response = await storageListWithHttpInfo(bucket,  prefix: prefix, );
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'StorageList200Response',) as StorageList200Response;
    
    }
    return null;
  }

  /// List buckets.
  ///
  /// Note: This method returns the HTTP [Response].
  Future<Response> storageListBucketsWithHttpInfo() async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/bucket';

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
    );
  }

  /// List buckets.
  Future<StorageListBuckets200Response?> storageListBuckets() async {
    final response = await storageListBucketsWithHttpInfo();
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'StorageListBuckets200Response',) as StorageListBuckets200Response;
    
    }
    return null;
  }

  /// Create a presigned URL (PUT or GET, TTL-clamped).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  ///
  /// * [StorageSignRequest] storageSignRequest:
  Future<Response> storageSignWithHttpInfo(String bucket, String key, { StorageSignRequest? storageSignRequest, }) async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/sign/{bucket}/{key}'
      .replaceAll('{bucket}', bucket)
      .replaceAll('{key}', key);

    // ignore: prefer_final_locals
    Object? postBody = storageSignRequest;

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
    );
  }

  /// Create a presigned URL (PUT or GET, TTL-clamped).
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  ///
  /// * [StorageSignRequest] storageSignRequest:
  Future<SignedUrl?> storageSign(String bucket, String key, { StorageSignRequest? storageSignRequest, }) async {
    final response = await storageSignWithHttpInfo(bucket, key,  storageSignRequest: storageSignRequest, );
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'SignedUrl',) as SignedUrl;
    
    }
    return null;
  }

  /// Upload (owner-prefixed) — body is the raw object bytes.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  ///
  /// * [MultipartFile] body (required):
  Future<Response> storageUploadWithHttpInfo(String bucket, String key, MultipartFile body,) async {
    // ignore: prefer_const_declarations
    final path = r'/storage/v1/object/{bucket}/{key}'
      .replaceAll('{bucket}', bucket)
      .replaceAll('{key}', key);

    // ignore: prefer_final_locals
    Object? postBody = body;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/octet-stream'];


    return apiClient.invokeAPI(
      path,
      'PUT',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
    );
  }

  /// Upload (owner-prefixed) — body is the raw object bytes.
  ///
  /// Parameters:
  ///
  /// * [String] bucket (required):
  ///
  /// * [String] key (required):
  ///
  /// * [MultipartFile] body (required):
  Future<UploadResult?> storageUpload(String bucket, String key, MultipartFile body,) async {
    final response = await storageUploadWithHttpInfo(bucket, key, body,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'UploadResult',) as UploadResult;
    
    }
    return null;
  }
}
