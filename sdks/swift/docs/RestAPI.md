# RestAPI

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**restDelete**](RestAPI.md#restdelete) | **DELETE** /rest/v1/{resource} | Delete rows matching the filter.
[**restInsert**](RestAPI.md#restinsert) | **POST** /rest/v1/{resource} | Insert one or many rows.
[**restRpc**](RestAPI.md#restrpc) | **POST** /rest/v1/rpc/{fn} | Call a Postgres stored function (PostgREST RPC).
[**restSelect**](RestAPI.md#restselect) | **GET** /rest/v1/{resource} | Select rows (PostgREST filters via query params).
[**restUpdate**](RestAPI.md#restupdate) | **PATCH** /rest/v1/{resource} | Update rows matching the filter.


# **restDelete**
```swift
    open class func restDelete(resource: String, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Delete rows matching the filter.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let resource = "resource_example" // String | Table or view name.

// Delete rows matching the filter.
RestAPI.restDelete(resource: resource) { (response, error) in
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
 **resource** | **String** | Table or view name. | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **restInsert**
```swift
    open class func restInsert(resource: String, requestBody: [String: AnyCodable], completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Insert one or many rows.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let resource = "resource_example" // String | Table or view name.
let requestBody = "TODO" // [String: AnyCodable] | 

// Insert one or many rows.
RestAPI.restInsert(resource: resource, requestBody: requestBody) { (response, error) in
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
 **resource** | **String** | Table or view name. | 
 **requestBody** | [**[String: AnyCodable]**](AnyCodable.md) |  | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **restRpc**
```swift
    open class func restRpc(fn: String, requestBody: [String: AnyCodable]? = nil, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Call a Postgres stored function (PostgREST RPC).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let fn = "fn_example" // String | 
let requestBody = "TODO" // [String: AnyCodable] |  (optional)

// Call a Postgres stored function (PostgREST RPC).
RestAPI.restRpc(fn: fn, requestBody: requestBody) { (response, error) in
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
 **fn** | **String** |  | 
 **requestBody** | [**[String: AnyCodable]**](AnyCodable.md) |  | [optional] 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **restSelect**
```swift
    open class func restSelect(resource: String, select: String? = nil, order: String? = nil, limit: Int? = nil, offset: Int? = nil, completion: @escaping (_ data: [AnyCodable]?, _ error: Error?) -> Void)
```

Select rows (PostgREST filters via query params).

Filters are PostgREST `column=op.value` query params (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`), plus `select`, `order`, `limit`, `offset`, and `or`. Send `Accept: application/vnd.pgrst.object+json` for `.single()`.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let resource = "resource_example" // String | Table or view name.
let select = "select_example" // String |  (optional)
let order = "order_example" // String |  (optional)
let limit = 987 // Int |  (optional)
let offset = 987 // Int |  (optional)

// Select rows (PostgREST filters via query params).
RestAPI.restSelect(resource: resource, select: select, order: order, limit: limit, offset: offset) { (response, error) in
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
 **resource** | **String** | Table or view name. | 
 **select** | **String** |  | [optional] 
 **order** | **String** |  | [optional] 
 **limit** | **Int** |  | [optional] 
 **offset** | **Int** |  | [optional] 

### Return type

**[AnyCodable]**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **restUpdate**
```swift
    open class func restUpdate(resource: String, requestBody: [String: AnyCodable], completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Update rows matching the filter.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let resource = "resource_example" // String | Table or view name.
let requestBody = "TODO" // [String: AnyCodable] | 

// Update rows matching the filter.
RestAPI.restUpdate(resource: resource, requestBody: requestBody) { (response, error) in
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
 **resource** | **String** | Table or view name. | 
 **requestBody** | [**[String: AnyCodable]**](AnyCodable.md) |  | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

