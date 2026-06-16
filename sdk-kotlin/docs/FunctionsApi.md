# FunctionsApi

All URIs are relative to *http://127.0.0.1:8002*

| Method | HTTP request | Description |
| ------------- | ------------- | ------------- |
| [**functionDelete**](FunctionsApi.md#functionDelete) | **DELETE** /functions/v1/{name} | Delete a deployed function. |
| [**functionGet**](FunctionsApi.md#functionGet) | **GET** /functions/v1/{name} | Get a deployed function&#39;s source. |
| [**functionInvoke**](FunctionsApi.md#functionInvoke) | **POST** /functions/v1/{name}/invoke | Invoke a deployed edge function. |


<a id="functionDelete"></a>
# **functionDelete**
> functionDelete(name)

Delete a deployed function.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = FunctionsApi()
val name : kotlin.String = name_example // kotlin.String | 
try {
    apiInstance.functionDelete(name)
} catch (e: ClientException) {
    println("4xx response calling FunctionsApi#functionDelete")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling FunctionsApi#functionDelete")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **name** | **kotlin.String**|  | |

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

<a id="functionGet"></a>
# **functionGet**
> FunctionGet200Response functionGet(name)

Get a deployed function&#39;s source.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = FunctionsApi()
val name : kotlin.String = name_example // kotlin.String | 
try {
    val result : FunctionGet200Response = apiInstance.functionGet(name)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling FunctionsApi#functionGet")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling FunctionsApi#functionGet")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **name** | **kotlin.String**|  | |

### Return type

[**FunctionGet200Response**](FunctionGet200Response.md)

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

<a id="functionInvoke"></a>
# **functionInvoke**
> functionInvoke(name, requestBody)

Invoke a deployed edge function.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = FunctionsApi()
val name : kotlin.String = name_example // kotlin.String | 
val requestBody : kotlin.collections.Map<kotlin.String, kotlin.Any> = Object // kotlin.collections.Map<kotlin.String, kotlin.Any> | 
try {
    apiInstance.functionInvoke(name, requestBody)
} catch (e: ClientException) {
    println("4xx response calling FunctionsApi#functionInvoke")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling FunctionsApi#functionInvoke")
    e.printStackTrace()
}
```

### Parameters
| **name** | **kotlin.String**|  | |
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

