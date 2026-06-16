# StorageApi

All URIs are relative to *http://127.0.0.1:8002*

| Method | HTTP request | Description |
| ------------- | ------------- | ------------- |
| [**storageCreateBucket**](StorageApi.md#storageCreateBucket) | **POST** /storage/v1/bucket/{name} | Create a bucket. |
| [**storageDelete**](StorageApi.md#storageDelete) | **DELETE** /storage/v1/object/{bucket}/{key} | Delete an object. |
| [**storageDownload**](StorageApi.md#storageDownload) | **GET** /storage/v1/object/{bucket}/{key} | Download object bytes (owner-scoped). |
| [**storageList**](StorageApi.md#storageList) | **GET** /storage/v1/list/{bucket} | List objects under a prefix (owner-scoped). |
| [**storageListBuckets**](StorageApi.md#storageListBuckets) | **GET** /storage/v1/bucket | List buckets. |
| [**storageSign**](StorageApi.md#storageSign) | **POST** /storage/v1/sign/{bucket}/{key} | Create a presigned URL (PUT or GET, TTL-clamped). |
| [**storageUpload**](StorageApi.md#storageUpload) | **PUT** /storage/v1/object/{bucket}/{key} | Upload (owner-prefixed) — body is the raw object bytes. |


<a id="storageCreateBucket"></a>
# **storageCreateBucket**
> StorageCreateBucket200Response storageCreateBucket(name)

Create a bucket.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
val name : kotlin.String = name_example // kotlin.String | 
try {
    val result : StorageCreateBucket200Response = apiInstance.storageCreateBucket(name)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageCreateBucket")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageCreateBucket")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **name** | **kotlin.String**|  | |

### Return type

[**StorageCreateBucket200Response**](StorageCreateBucket200Response.md)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

<a id="storageDelete"></a>
# **storageDelete**
> storageDelete(bucket, key)

Delete an object.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
val bucket : kotlin.String = bucket_example // kotlin.String | 
val key : kotlin.String = key_example // kotlin.String | 
try {
    apiInstance.storageDelete(bucket, key)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageDelete")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageDelete")
    e.printStackTrace()
}
```

### Parameters
| **bucket** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **key** | **kotlin.String**|  | |

### Return type

null (empty response body)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

<a id="storageDownload"></a>
# **storageDownload**
> java.io.File storageDownload(bucket, key)

Download object bytes (owner-scoped).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
val bucket : kotlin.String = bucket_example // kotlin.String | 
val key : kotlin.String = key_example // kotlin.String | 
try {
    val result : java.io.File = apiInstance.storageDownload(bucket, key)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageDownload")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageDownload")
    e.printStackTrace()
}
```

### Parameters
| **bucket** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **key** | **kotlin.String**|  | |

### Return type

[**java.io.File**](java.io.File.md)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/octet-stream, application/json

<a id="storageList"></a>
# **storageList**
> StorageList200Response storageList(bucket, prefix)

List objects under a prefix (owner-scoped).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
val bucket : kotlin.String = bucket_example // kotlin.String | 
val prefix : kotlin.String = prefix_example // kotlin.String | 
try {
    val result : StorageList200Response = apiInstance.storageList(bucket, prefix)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageList")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageList")
    e.printStackTrace()
}
```

### Parameters
| **bucket** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **prefix** | **kotlin.String**|  | [optional] |

### Return type

[**StorageList200Response**](StorageList200Response.md)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

<a id="storageListBuckets"></a>
# **storageListBuckets**
> StorageListBuckets200Response storageListBuckets()

List buckets.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
try {
    val result : StorageListBuckets200Response = apiInstance.storageListBuckets()
    println(result)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageListBuckets")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageListBuckets")
    e.printStackTrace()
}
```

### Parameters
This endpoint does not need any parameter.

### Return type

[**StorageListBuckets200Response**](StorageListBuckets200Response.md)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

<a id="storageSign"></a>
# **storageSign**
> SignedUrl storageSign(bucket, key, storageSignRequest)

Create a presigned URL (PUT or GET, TTL-clamped).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
val bucket : kotlin.String = bucket_example // kotlin.String | 
val key : kotlin.String = key_example // kotlin.String | 
val storageSignRequest : StorageSignRequest =  // StorageSignRequest | 
try {
    val result : SignedUrl = apiInstance.storageSign(bucket, key, storageSignRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageSign")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageSign")
    e.printStackTrace()
}
```

### Parameters
| **bucket** | **kotlin.String**|  | |
| **key** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **storageSignRequest** | [**StorageSignRequest**](StorageSignRequest.md)|  | [optional] |

### Return type

[**SignedUrl**](SignedUrl.md)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

<a id="storageUpload"></a>
# **storageUpload**
> UploadResult storageUpload(bucket, key, body)

Upload (owner-prefixed) — body is the raw object bytes.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = StorageApi()
val bucket : kotlin.String = bucket_example // kotlin.String | 
val key : kotlin.String = key_example // kotlin.String | 
val body : java.io.File = BINARY_DATA_HERE // java.io.File | 
try {
    val result : UploadResult = apiInstance.storageUpload(bucket, key, body)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling StorageApi#storageUpload")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling StorageApi#storageUpload")
    e.printStackTrace()
}
```

### Parameters
| **bucket** | **kotlin.String**|  | |
| **key** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **body** | **java.io.File**|  | |

### Return type

[**UploadResult**](UploadResult.md)

### Authorization


Configure apiKey:
    ApiClient.apiKey["apikey"] = ""
    ApiClient.apiKeyPrefix["apikey"] = ""
Configure bearerAuth statically:
```kotlin
ApiClient.accessToken = ""
```
Configure bearerAuth dynamically:
```kotlin
apiInstance.accessTokenProvider = { "" }
```

### HTTP request headers

 - **Content-Type**: application/octet-stream
 - **Accept**: application/json

