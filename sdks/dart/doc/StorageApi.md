# grobase.api.StorageApi

## Load the API package
```dart
import 'package:grobase/api.dart';
```

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**storageCreateBucket**](StorageApi.md#storagecreatebucket) | **POST** /storage/v1/bucket/{name} | Create a bucket.
[**storageDelete**](StorageApi.md#storagedelete) | **DELETE** /storage/v1/object/{bucket}/{key} | Delete an object.
[**storageDownload**](StorageApi.md#storagedownload) | **GET** /storage/v1/object/{bucket}/{key} | Download object bytes (owner-scoped).
[**storageList**](StorageApi.md#storagelist) | **GET** /storage/v1/list/{bucket} | List objects under a prefix (owner-scoped).
[**storageListBuckets**](StorageApi.md#storagelistbuckets) | **GET** /storage/v1/bucket | List buckets.
[**storageSign**](StorageApi.md#storagesign) | **POST** /storage/v1/sign/{bucket}/{key} | Create a presigned URL (PUT or GET, TTL-clamped).
[**storageUpload**](StorageApi.md#storageupload) | **PUT** /storage/v1/object/{bucket}/{key} | Upload (owner-prefixed) — body is the raw object bytes.


# **storageCreateBucket**
> StorageCreateBucket200Response storageCreateBucket(name)

Create a bucket.

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

final api_instance = StorageApi();
final name = name_example; // String | 

try {
    final result = api_instance.storageCreateBucket(name);
    print(result);
} catch (e) {
    print('Exception when calling StorageApi->storageCreateBucket: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **name** | **String**|  | 

### Return type

[**StorageCreateBucket200Response**](StorageCreateBucket200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageDelete**
> storageDelete(bucket, key)

Delete an object.

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

final api_instance = StorageApi();
final bucket = bucket_example; // String | 
final key = key_example; // String | 

try {
    api_instance.storageDelete(bucket, key);
} catch (e) {
    print('Exception when calling StorageApi->storageDelete: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String**|  | 
 **key** | **String**|  | 

### Return type

void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageDownload**
> MultipartFile storageDownload(bucket, key)

Download object bytes (owner-scoped).

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

final api_instance = StorageApi();
final bucket = bucket_example; // String | 
final key = key_example; // String | 

try {
    final result = api_instance.storageDownload(bucket, key);
    print(result);
} catch (e) {
    print('Exception when calling StorageApi->storageDownload: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String**|  | 
 **key** | **String**|  | 

### Return type

[**MultipartFile**](MultipartFile.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/octet-stream, application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageList**
> StorageList200Response storageList(bucket, prefix)

List objects under a prefix (owner-scoped).

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

final api_instance = StorageApi();
final bucket = bucket_example; // String | 
final prefix = prefix_example; // String | 

try {
    final result = api_instance.storageList(bucket, prefix);
    print(result);
} catch (e) {
    print('Exception when calling StorageApi->storageList: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String**|  | 
 **prefix** | **String**|  | [optional] 

### Return type

[**StorageList200Response**](StorageList200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageListBuckets**
> StorageListBuckets200Response storageListBuckets()

List buckets.

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

final api_instance = StorageApi();

try {
    final result = api_instance.storageListBuckets();
    print(result);
} catch (e) {
    print('Exception when calling StorageApi->storageListBuckets: $e\n');
}
```

### Parameters
This endpoint does not need any parameter.

### Return type

[**StorageListBuckets200Response**](StorageListBuckets200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageSign**
> SignedUrl storageSign(bucket, key, storageSignRequest)

Create a presigned URL (PUT or GET, TTL-clamped).

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

final api_instance = StorageApi();
final bucket = bucket_example; // String | 
final key = key_example; // String | 
final storageSignRequest = StorageSignRequest(); // StorageSignRequest | 

try {
    final result = api_instance.storageSign(bucket, key, storageSignRequest);
    print(result);
} catch (e) {
    print('Exception when calling StorageApi->storageSign: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String**|  | 
 **key** | **String**|  | 
 **storageSignRequest** | [**StorageSignRequest**](StorageSignRequest.md)|  | [optional] 

### Return type

[**SignedUrl**](SignedUrl.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageUpload**
> UploadResult storageUpload(bucket, key, body)

Upload (owner-prefixed) — body is the raw object bytes.

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

final api_instance = StorageApi();
final bucket = bucket_example; // String | 
final key = key_example; // String | 
final body = MultipartFile(); // MultipartFile | 

try {
    final result = api_instance.storageUpload(bucket, key, body);
    print(result);
} catch (e) {
    print('Exception when calling StorageApi->storageUpload: $e\n');
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String**|  | 
 **key** | **String**|  | 
 **body** | **MultipartFile**|  | 

### Return type

[**UploadResult**](UploadResult.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/octet-stream
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

