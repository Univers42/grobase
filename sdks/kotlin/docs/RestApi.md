# RestApi

All URIs are relative to *http://127.0.0.1:8002*

| Method | HTTP request | Description |
| ------------- | ------------- | ------------- |
| [**restDelete**](RestApi.md#restDelete) | **DELETE** /rest/v1/{resource} | Delete rows matching the filter. |
| [**restInsert**](RestApi.md#restInsert) | **POST** /rest/v1/{resource} | Insert one or many rows. |
| [**restRpc**](RestApi.md#restRpc) | **POST** /rest/v1/rpc/{fn} | Call a Postgres stored function (PostgREST RPC). |
| [**restSelect**](RestApi.md#restSelect) | **GET** /rest/v1/{resource} | Select rows (PostgREST filters via query params). |
| [**restUpdate**](RestApi.md#restUpdate) | **PATCH** /rest/v1/{resource} | Update rows matching the filter. |


<a id="restDelete"></a>
# **restDelete**
> restDelete(resource)

Delete rows matching the filter.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = RestApi()
val resource : kotlin.String = resource_example // kotlin.String | Table or view name.
try {
    apiInstance.restDelete(resource)
} catch (e: ClientException) {
    println("4xx response calling RestApi#restDelete")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling RestApi#restDelete")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **resource** | **kotlin.String**| Table or view name. | |

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

<a id="restInsert"></a>
# **restInsert**
> restInsert(resource, requestBody)

Insert one or many rows.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = RestApi()
val resource : kotlin.String = resource_example // kotlin.String | Table or view name.
val requestBody : kotlin.collections.Map<kotlin.String, kotlin.Any> = Object // kotlin.collections.Map<kotlin.String, kotlin.Any> | 
try {
    apiInstance.restInsert(resource, requestBody)
} catch (e: ClientException) {
    println("4xx response calling RestApi#restInsert")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling RestApi#restInsert")
    e.printStackTrace()
}
```

### Parameters
| **resource** | **kotlin.String**| Table or view name. | |
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
 - **Accept**: application/json

<a id="restRpc"></a>
# **restRpc**
> restRpc(fn, requestBody)

Call a Postgres stored function (PostgREST RPC).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = RestApi()
val fn : kotlin.String = fn_example // kotlin.String | 
val requestBody : kotlin.collections.Map<kotlin.String, kotlin.Any> = Object // kotlin.collections.Map<kotlin.String, kotlin.Any> | 
try {
    apiInstance.restRpc(fn, requestBody)
} catch (e: ClientException) {
    println("4xx response calling RestApi#restRpc")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling RestApi#restRpc")
    e.printStackTrace()
}
```

### Parameters
| **fn** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **requestBody** | [**kotlin.collections.Map&lt;kotlin.String, kotlin.Any&gt;**](kotlin.Any.md)|  | [optional] |

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

<a id="restSelect"></a>
# **restSelect**
> kotlin.collections.List&lt;kotlin.Any&gt; restSelect(resource, select, order, limit, offset)

Select rows (PostgREST filters via query params).

Filters are PostgREST &#x60;column&#x3D;op.value&#x60; query params (&#x60;eq&#x60;, &#x60;neq&#x60;, &#x60;gt&#x60;, &#x60;gte&#x60;, &#x60;lt&#x60;, &#x60;lte&#x60;, &#x60;like&#x60;, &#x60;ilike&#x60;, &#x60;is&#x60;, &#x60;in&#x60;), plus &#x60;select&#x60;, &#x60;order&#x60;, &#x60;limit&#x60;, &#x60;offset&#x60;, and &#x60;or&#x60;. Send &#x60;Accept: application/vnd.pgrst.object+json&#x60; for &#x60;.single()&#x60;.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = RestApi()
val resource : kotlin.String = resource_example // kotlin.String | Table or view name.
val select : kotlin.String = select_example // kotlin.String | 
val order : kotlin.String = order_example // kotlin.String | 
val limit : kotlin.Int = 56 // kotlin.Int | 
val offset : kotlin.Int = 56 // kotlin.Int | 
try {
    val result : kotlin.collections.List<kotlin.Any> = apiInstance.restSelect(resource, select, order, limit, offset)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling RestApi#restSelect")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling RestApi#restSelect")
    e.printStackTrace()
}
```

### Parameters
| **resource** | **kotlin.String**| Table or view name. | |
| **select** | **kotlin.String**|  | [optional] |
| **order** | **kotlin.String**|  | [optional] |
| **limit** | **kotlin.Int**|  | [optional] |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **offset** | **kotlin.Int**|  | [optional] |

### Return type

[**kotlin.collections.List&lt;kotlin.Any&gt;**](kotlin.Any.md)

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

<a id="restUpdate"></a>
# **restUpdate**
> restUpdate(resource, requestBody)

Update rows matching the filter.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = RestApi()
val resource : kotlin.String = resource_example // kotlin.String | Table or view name.
val requestBody : kotlin.collections.Map<kotlin.String, kotlin.Any> = Object // kotlin.collections.Map<kotlin.String, kotlin.Any> | 
try {
    apiInstance.restUpdate(resource, requestBody)
} catch (e: ClientException) {
    println("4xx response calling RestApi#restUpdate")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling RestApi#restUpdate")
    e.printStackTrace()
}
```

### Parameters
| **resource** | **kotlin.String**| Table or view name. | |
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

