# grobase.api.QueryApi

## Load the API package
```dart
import 'package:grobase/api.dart';
```

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**queryEngines**](QueryApi.md#queryengines) | **GET** /query/v1/engines | List registered engines + capabilities.
[**queryExecute**](QueryApi.md#queryexecute) | **POST** /query/v1/execute | Run one engine-agnostic data operation against a mount.
[**querySchema**](QueryApi.md#queryschema) | **GET** /query/v1/{dbId}/schema | Introspect a mount's tables + live engine capabilities.
[**querySchemaDdl**](QueryApi.md#queryschemaddl) | **POST** /query/v1/{dbId}/schema/ddl | Apply ONE schema-DDL operation to a mount.
[**queryTxn**](QueryApi.md#querytxn) | **POST** /query/v1/txn | Single-mount atomic write batch (all-or-nothing).


# **queryEngines**
> QueryEngines200Response queryEngines()

List registered engines + capabilities.

### Example
```dart
import 'package:grobase/api.dart';
// TODO Configure API key authorization: apiKey
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKey = 'YOUR_API_KEY';
// uncomment below to setup prefix (e.g. Bearer) for API key, if needed
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKeyPrefix = 'Bearer';
// TODO Configure HTTP Bearer authorization: bearerAuth
// Case 1. Use String Token
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken('YOUR_ACCESS_TOKEN');
// Case 2. Use Function which generate token.
// String yourTokenGeneratorFunction() { ... }
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken(yourTokenGeneratorFunction);

final api_instance = QueryApi();

try {
    final result = api_instance.queryEngines();
    print(result);
} catch (e) {
    print('Exception when calling QueryApi->queryEngines: $e\n');
}
```

### Parameters
This endpoint does not need any parameter.

### Return type

[**QueryEngines200Response**](QueryEngines200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **queryExecute**
> QueryResponse queryExecute(queryRequest)

Run one engine-agnostic data operation against a mount.

### Example
```dart
import 'package:grobase/api.dart';
// TODO Configure API key authorization: apiKey
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKey = 'YOUR_API_KEY';
// uncomment below to setup prefix (e.g. Bearer) for API key, if needed
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKeyPrefix = 'Bearer';
// TODO Configure HTTP Bearer authorization: bearerAuth
// Case 1. Use String Token
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken('YOUR_ACCESS_TOKEN');
// Case 2. Use Function which generate token.
// String yourTokenGeneratorFunction() { ... }
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken(yourTokenGeneratorFunction);

final api_instance = QueryApi();
final queryRequest = QueryRequest(); // QueryRequest | 

try {
    final result = api_instance.queryExecute(queryRequest);
    print(result);
} catch (e) {
    print('Exception when calling QueryApi->queryExecute: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **queryRequest** | [**QueryRequest**](QueryRequest.md)|  | 

### Return type

[**QueryResponse**](QueryResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **querySchema**
> Map<String, Object> querySchema(dbId)

Introspect a mount's tables + live engine capabilities.

### Example
```dart
import 'package:grobase/api.dart';
// TODO Configure API key authorization: apiKey
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKey = 'YOUR_API_KEY';
// uncomment below to setup prefix (e.g. Bearer) for API key, if needed
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKeyPrefix = 'Bearer';
// TODO Configure HTTP Bearer authorization: bearerAuth
// Case 1. Use String Token
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken('YOUR_ACCESS_TOKEN');
// Case 2. Use Function which generate token.
// String yourTokenGeneratorFunction() { ... }
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken(yourTokenGeneratorFunction);

final api_instance = QueryApi();
final dbId = dbId_example; // String | 

try {
    final result = api_instance.querySchema(dbId);
    print(result);
} catch (e) {
    print('Exception when calling QueryApi->querySchema: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **dbId** | **String**|  | 

### Return type

**Map<String, Object>**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **querySchemaDdl**
> querySchemaDdl(dbId, requestBody)

Apply ONE schema-DDL operation to a mount.

### Example
```dart
import 'package:grobase/api.dart';
// TODO Configure API key authorization: apiKey
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKey = 'YOUR_API_KEY';
// uncomment below to setup prefix (e.g. Bearer) for API key, if needed
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKeyPrefix = 'Bearer';
// TODO Configure HTTP Bearer authorization: bearerAuth
// Case 1. Use String Token
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken('YOUR_ACCESS_TOKEN');
// Case 2. Use Function which generate token.
// String yourTokenGeneratorFunction() { ... }
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken(yourTokenGeneratorFunction);

final api_instance = QueryApi();
final dbId = dbId_example; // String | 
final requestBody = Map<String, Object>(); // Map<String, Object> | 

try {
    api_instance.querySchemaDdl(dbId, requestBody);
} catch (e) {
    print('Exception when calling QueryApi->querySchemaDdl: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **dbId** | **String**|  | 
 **requestBody** | [**Map<String, Object>**](Object.md)|  | 

### Return type

void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **queryTxn**
> TxnResponse queryTxn(txnRequest)

Single-mount atomic write batch (all-or-nothing).

### Example
```dart
import 'package:grobase/api.dart';
// TODO Configure API key authorization: apiKey
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKey = 'YOUR_API_KEY';
// uncomment below to setup prefix (e.g. Bearer) for API key, if needed
//defaultApiClient.getAuthentication<ApiKeyAuth>('apiKey').apiKeyPrefix = 'Bearer';
// TODO Configure HTTP Bearer authorization: bearerAuth
// Case 1. Use String Token
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken('YOUR_ACCESS_TOKEN');
// Case 2. Use Function which generate token.
// String yourTokenGeneratorFunction() { ... }
//defaultApiClient.getAuthentication<HttpBearerAuth>('bearerAuth').setAccessToken(yourTokenGeneratorFunction);

final api_instance = QueryApi();
final txnRequest = TxnRequest(); // TxnRequest | 

try {
    final result = api_instance.queryTxn(txnRequest);
    print(result);
} catch (e) {
    print('Exception when calling QueryApi->queryTxn: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **txnRequest** | [**TxnRequest**](TxnRequest.md)|  | 

### Return type

[**TxnResponse**](TxnResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

