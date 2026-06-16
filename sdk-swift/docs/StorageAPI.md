# StorageAPI

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**storageCreateBucket**](StorageAPI.md#storagecreatebucket) | **POST** /storage/v1/bucket/{name} | Create a bucket.
[**storageDelete**](StorageAPI.md#storagedelete) | **DELETE** /storage/v1/object/{bucket}/{key} | Delete an object.
[**storageDownload**](StorageAPI.md#storagedownload) | **GET** /storage/v1/object/{bucket}/{key} | Download object bytes (owner-scoped).
[**storageList**](StorageAPI.md#storagelist) | **GET** /storage/v1/list/{bucket} | List objects under a prefix (owner-scoped).
[**storageListBuckets**](StorageAPI.md#storagelistbuckets) | **GET** /storage/v1/bucket | List buckets.
[**storageSign**](StorageAPI.md#storagesign) | **POST** /storage/v1/sign/{bucket}/{key} | Create a presigned URL (PUT or GET, TTL-clamped).
[**storageUpload**](StorageAPI.md#storageupload) | **PUT** /storage/v1/object/{bucket}/{key} | Upload (owner-prefixed) — body is the raw object bytes.


# **storageCreateBucket**
```swift
    open class func storageCreateBucket(name: String, completion: @escaping (_ data: StorageCreateBucket200Response?, _ error: Error?) -> Void)
```

Create a bucket.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let name = "name_example" // String | 

// Create a bucket.
StorageAPI.storageCreateBucket(name: name) { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **name** | **String** |  | 

### Return type

[**StorageCreateBucket200Response**](StorageCreateBucket200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageDelete**
```swift
    open class func storageDelete(bucket: String, key: String, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Delete an object.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let bucket = "bucket_example" // String | 
let key = "key_example" // String | 

// Delete an object.
StorageAPI.storageDelete(bucket: bucket, key: key) { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String** |  | 
 **key** | **String** |  | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageDownload**
```swift
    open class func storageDownload(bucket: String, key: String, completion: @escaping (_ data: URL?, _ error: Error?) -> Void)
```

Download object bytes (owner-scoped).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let bucket = "bucket_example" // String | 
let key = "key_example" // String | 

// Download object bytes (owner-scoped).
StorageAPI.storageDownload(bucket: bucket, key: key) { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String** |  | 
 **key** | **String** |  | 

### Return type

**URL**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/octet-stream, application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageList**
```swift
    open class func storageList(bucket: String, _prefix: String? = nil, completion: @escaping (_ data: StorageList200Response?, _ error: Error?) -> Void)
```

List objects under a prefix (owner-scoped).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let bucket = "bucket_example" // String | 
let _prefix = "_prefix_example" // String |  (optional)

// List objects under a prefix (owner-scoped).
StorageAPI.storageList(bucket: bucket, _prefix: _prefix) { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String** |  | 
 **_prefix** | **String** |  | [optional] 

### Return type

[**StorageList200Response**](StorageList200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageListBuckets**
```swift
    open class func storageListBuckets(completion: @escaping (_ data: StorageListBuckets200Response?, _ error: Error?) -> Void)
```

List buckets.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase


// List buckets.
StorageAPI.storageListBuckets() { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
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
```swift
    open class func storageSign(bucket: String, key: String, storageSignRequest: StorageSignRequest? = nil, completion: @escaping (_ data: SignedUrl?, _ error: Error?) -> Void)
```

Create a presigned URL (PUT or GET, TTL-clamped).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let bucket = "bucket_example" // String | 
let key = "key_example" // String | 
let storageSignRequest = storageSign_request(method: "method_example", expiresIn: 123, contentType: "contentType_example") // StorageSignRequest |  (optional)

// Create a presigned URL (PUT or GET, TTL-clamped).
StorageAPI.storageSign(bucket: bucket, key: key, storageSignRequest: storageSignRequest) { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String** |  | 
 **key** | **String** |  | 
 **storageSignRequest** | [**StorageSignRequest**](StorageSignRequest.md) |  | [optional] 

### Return type

[**SignedUrl**](SignedUrl.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storageUpload**
```swift
    open class func storageUpload(bucket: String, key: String, body: URL, completion: @escaping (_ data: UploadResult?, _ error: Error?) -> Void)
```

Upload (owner-prefixed) — body is the raw object bytes.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let bucket = "bucket_example" // String | 
let key = "key_example" // String | 
let body = URL(string: "https://example.com")! // URL | 

// Upload (owner-prefixed) — body is the raw object bytes.
StorageAPI.storageUpload(bucket: bucket, key: key, body: body) { (response, error) in
    guard error == nil else {
        print(error)
        return
    }

    if (response) {
        dump(response)
    }
}
```

### Parameters

Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **String** |  | 
 **key** | **String** |  | 
 **body** | **URL** |  | 

### Return type

[**UploadResult**](UploadResult.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/octet-stream
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

