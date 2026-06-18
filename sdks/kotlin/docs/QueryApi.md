# QueryApi

All URIs are relative to *http://127.0.0.1:8002*

| Method | HTTP request | Description |
| ------------- | ------------- | ------------- |
| [**queryEngines**](QueryApi.md#queryEngines) | **GET** /query/v1/engines | List registered engines + capabilities. |
| [**queryExecute**](QueryApi.md#queryExecute) | **POST** /query/v1/execute | Run one engine-agnostic data operation against a mount. |
| [**querySchema**](QueryApi.md#querySchema) | **GET** /query/v1/{dbId}/schema | Introspect a mount&#39;s tables + live engine capabilities. |
| [**querySchemaDdl**](QueryApi.md#querySchemaDdl) | **POST** /query/v1/{dbId}/schema/ddl | Apply ONE schema-DDL operation to a mount. |
| [**queryTxn**](QueryApi.md#queryTxn) | **POST** /query/v1/txn | Single-mount atomic write batch (all-or-nothing). |


<a id="queryEngines"></a>
# **queryEngines**
> QueryEngines200Response queryEngines()

List registered engines + capabilities.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = QueryApi()
try {
    val result : QueryEngines200Response = apiInstance.queryEngines()
    println(result)
} catch (e: ClientException) {
    println("4xx response calling QueryApi#queryEngines")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling QueryApi#queryEngines")
    e.printStackTrace()
}
```

### Parameters
This endpoint does not need any parameter.

### Return type

[**QueryEngines200Response**](QueryEngines200Response.md)

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

<a id="queryExecute"></a>
# **queryExecute**
> QueryResponse queryExecute(queryRequest)

Run one engine-agnostic data operation against a mount.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = QueryApi()
val queryRequest : QueryRequest =  // QueryRequest | 
try {
    val result : QueryResponse = apiInstance.queryExecute(queryRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling QueryApi#queryExecute")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling QueryApi#queryExecute")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **queryRequest** | [**QueryRequest**](QueryRequest.md)|  | |

### Return type

[**QueryResponse**](QueryResponse.md)

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

<a id="querySchema"></a>
# **querySchema**
> kotlin.collections.Map&lt;kotlin.String, kotlin.Any&gt; querySchema(dbId)

Introspect a mount&#39;s tables + live engine capabilities.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = QueryApi()
val dbId : kotlin.String = dbId_example // kotlin.String | 
try {
    val result : kotlin.collections.Map<kotlin.String, kotlin.Any> = apiInstance.querySchema(dbId)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling QueryApi#querySchema")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling QueryApi#querySchema")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **dbId** | **kotlin.String**|  | |

### Return type

[**kotlin.collections.Map&lt;kotlin.String, kotlin.Any&gt;**](kotlin.Any.md)

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

<a id="querySchemaDdl"></a>
# **querySchemaDdl**
> querySchemaDdl(dbId, requestBody)

Apply ONE schema-DDL operation to a mount.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = QueryApi()
val dbId : kotlin.String = dbId_example // kotlin.String | 
val requestBody : kotlin.collections.Map<kotlin.String, kotlin.Any> = Object // kotlin.collections.Map<kotlin.String, kotlin.Any> | 
try {
    apiInstance.querySchemaDdl(dbId, requestBody)
} catch (e: ClientException) {
    println("4xx response calling QueryApi#querySchemaDdl")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling QueryApi#querySchemaDdl")
    e.printStackTrace()
}
```

### Parameters
| **dbId** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **requestBody** | [**kotlin.collections.Map&lt;kotlin.String, kotlin.Any&gt;**](kotlin.Any.md)|  | |

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

 - **Content-Type**: application/json
 - **Accept**: Not defined

<a id="queryTxn"></a>
# **queryTxn**
> TxnResponse queryTxn(txnRequest)

Single-mount atomic write batch (all-or-nothing).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = QueryApi()
val txnRequest : TxnRequest =  // TxnRequest | 
try {
    val result : TxnResponse = apiInstance.queryTxn(txnRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling QueryApi#queryTxn")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling QueryApi#queryTxn")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **txnRequest** | [**TxnRequest**](TxnRequest.md)|  | |

### Return type

[**TxnResponse**](TxnResponse.md)

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

