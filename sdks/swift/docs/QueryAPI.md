# QueryAPI

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**queryEngines**](QueryAPI.md#queryengines) | **GET** /query/v1/engines | List registered engines + capabilities.
[**queryExecute**](QueryAPI.md#queryexecute) | **POST** /query/v1/execute | Run one engine-agnostic data operation against a mount.
[**querySchema**](QueryAPI.md#queryschema) | **GET** /query/v1/{dbId}/schema | Introspect a mount&#39;s tables + live engine capabilities.
[**querySchemaDdl**](QueryAPI.md#queryschemaddl) | **POST** /query/v1/{dbId}/schema/ddl | Apply ONE schema-DDL operation to a mount.
[**queryTxn**](QueryAPI.md#querytxn) | **POST** /query/v1/txn | Single-mount atomic write batch (all-or-nothing).


# **queryEngines**
```swift
    open class func queryEngines(completion: @escaping (_ data: QueryEngines200Response?, _ error: Error?) -> Void)
```

List registered engines + capabilities.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase


// List registered engines + capabilities.
QueryAPI.queryEngines() { (response, error) in
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

[**QueryEngines200Response**](QueryEngines200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **queryExecute**
```swift
    open class func queryExecute(queryRequest: QueryRequest, completion: @escaping (_ data: QueryResponse?, _ error: Error?) -> Void)
```

Run one engine-agnostic data operation against a mount.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let queryRequest = QueryRequest(databaseId: "databaseId_example", action: "action_example", resource: "resource_example", payload: "TODO") // QueryRequest | 

// Run one engine-agnostic data operation against a mount.
QueryAPI.queryExecute(queryRequest: queryRequest) { (response, error) in
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
 **queryRequest** | [**QueryRequest**](QueryRequest.md) |  | 

### Return type

[**QueryResponse**](QueryResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **querySchema**
```swift
    open class func querySchema(dbId: String, completion: @escaping (_ data: [String: AnyCodable]?, _ error: Error?) -> Void)
```

Introspect a mount's tables + live engine capabilities.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let dbId = "dbId_example" // String | 

// Introspect a mount's tables + live engine capabilities.
QueryAPI.querySchema(dbId: dbId) { (response, error) in
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
 **dbId** | **String** |  | 

### Return type

**[String: AnyCodable]**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **querySchemaDdl**
```swift
    open class func querySchemaDdl(dbId: String, requestBody: [String: AnyCodable], completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Apply ONE schema-DDL operation to a mount.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let dbId = "dbId_example" // String | 
let requestBody = "TODO" // [String: AnyCodable] | 

// Apply ONE schema-DDL operation to a mount.
QueryAPI.querySchemaDdl(dbId: dbId, requestBody: requestBody) { (response, error) in
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
 **dbId** | **String** |  | 
 **requestBody** | [**[String: AnyCodable]**](AnyCodable.md) |  | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **queryTxn**
```swift
    open class func queryTxn(txnRequest: TxnRequest, completion: @escaping (_ data: TxnResponse?, _ error: Error?) -> Void)
```

Single-mount atomic write batch (all-or-nothing).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let txnRequest = TxnRequest(databaseId: "databaseId_example", operations: [TxnRequest_operations_inner(op: "op_example", resource: "resource_example", data: "TODO", filter: "TODO", idempotencyKey: "idempotencyKey_example")]) // TxnRequest | 

// Single-mount atomic write batch (all-or-nothing).
QueryAPI.queryTxn(txnRequest: txnRequest) { (response, error) in
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
 **txnRequest** | [**TxnRequest**](TxnRequest.md) |  | 

### Return type

[**TxnResponse**](TxnResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

