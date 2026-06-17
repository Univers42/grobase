# FunctionsAPI

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**functionDelete**](FunctionsAPI.md#functiondelete) | **DELETE** /functions/v1/{name} | Delete a deployed function.
[**functionGet**](FunctionsAPI.md#functionget) | **GET** /functions/v1/{name} | Get a deployed function&#39;s source.
[**functionInvoke**](FunctionsAPI.md#functioninvoke) | **POST** /functions/v1/{name}/invoke | Invoke a deployed edge function.


# **functionDelete**
```swift
    open class func functionDelete(name: String, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Delete a deployed function.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let name = "name_example" // String | 

// Delete a deployed function.
FunctionsAPI.functionDelete(name: name) { (response, error) in
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

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **functionGet**
```swift
    open class func functionGet(name: String, completion: @escaping (_ data: FunctionGet200Response?, _ error: Error?) -> Void)
```

Get a deployed function's source.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let name = "name_example" // String | 

// Get a deployed function's source.
FunctionsAPI.functionGet(name: name) { (response, error) in
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

[**FunctionGet200Response**](FunctionGet200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **functionInvoke**
```swift
    open class func functionInvoke(name: String, requestBody: [String: AnyCodable]? = nil, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Invoke a deployed edge function.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let name = "name_example" // String | 
let requestBody = "TODO" // [String: AnyCodable] |  (optional)

// Invoke a deployed edge function.
FunctionsAPI.functionInvoke(name: name, requestBody: requestBody) { (response, error) in
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
 **requestBody** | [**[String: AnyCodable]**](AnyCodable.md) |  | [optional] 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

