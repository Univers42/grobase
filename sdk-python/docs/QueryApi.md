# grobase.QueryApi

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**query_engines**](QueryApi.md#query_engines) | **GET** /query/v1/engines | List registered engines + capabilities.
[**query_execute**](QueryApi.md#query_execute) | **POST** /query/v1/execute | Run one engine-agnostic data operation against a mount.
[**query_schema**](QueryApi.md#query_schema) | **GET** /query/v1/{dbId}/schema | Introspect a mount&#39;s tables + live engine capabilities.
[**query_schema_ddl**](QueryApi.md#query_schema_ddl) | **POST** /query/v1/{dbId}/schema/ddl | Apply ONE schema-DDL operation to a mount.
[**query_txn**](QueryApi.md#query_txn) | **POST** /query/v1/txn | Single-mount atomic write batch (all-or-nothing).


# **query_engines**
> QueryEngines200Response query_engines()

List registered engines + capabilities.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.query_engines200_response import QueryEngines200Response
from grobase.rest import ApiException
from pprint import pprint

# Defining the host is optional and defaults to http://127.0.0.1:8002
# See configuration.py for a list of all supported configuration parameters.
configuration = grobase.Configuration(
    host = "http://127.0.0.1:8002"
)

# The client must configure the authentication and authorization parameters
# in accordance with the API server security policy.
# Examples for each auth method are provided below, use the example that
# satisfies your auth use case.

# Configure API key authorization: apiKey
configuration.api_key['apiKey'] = os.environ["API_KEY"]

# Uncomment below to setup prefix (e.g. Bearer) for API key, if needed
# configuration.api_key_prefix['apiKey'] = 'Bearer'

# Configure Bearer authorization (JWT): bearerAuth
configuration = grobase.Configuration(
    access_token = os.environ["BEARER_TOKEN"]
)

# Enter a context with an instance of the API client
with grobase.ApiClient(configuration) as api_client:
    # Create an instance of the API class
    api_instance = grobase.QueryApi(api_client)

    try:
        # List registered engines + capabilities.
        api_response = api_instance.query_engines()
        print("The response of QueryApi->query_engines:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling QueryApi->query_engines: %s\n" % e)
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

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Engines. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **query_execute**
> QueryResponse query_execute(query_request)

Run one engine-agnostic data operation against a mount.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.query_request import QueryRequest
from grobase.models.query_response import QueryResponse
from grobase.rest import ApiException
from pprint import pprint

# Defining the host is optional and defaults to http://127.0.0.1:8002
# See configuration.py for a list of all supported configuration parameters.
configuration = grobase.Configuration(
    host = "http://127.0.0.1:8002"
)

# The client must configure the authentication and authorization parameters
# in accordance with the API server security policy.
# Examples for each auth method are provided below, use the example that
# satisfies your auth use case.

# Configure API key authorization: apiKey
configuration.api_key['apiKey'] = os.environ["API_KEY"]

# Uncomment below to setup prefix (e.g. Bearer) for API key, if needed
# configuration.api_key_prefix['apiKey'] = 'Bearer'

# Configure Bearer authorization (JWT): bearerAuth
configuration = grobase.Configuration(
    access_token = os.environ["BEARER_TOKEN"]
)

# Enter a context with an instance of the API client
with grobase.ApiClient(configuration) as api_client:
    # Create an instance of the API class
    api_instance = grobase.QueryApi(api_client)
    query_request = grobase.QueryRequest() # QueryRequest | 

    try:
        # Run one engine-agnostic data operation against a mount.
        api_response = api_instance.query_execute(query_request)
        print("The response of QueryApi->query_execute:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling QueryApi->query_execute: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **query_request** | [**QueryRequest**](QueryRequest.md)|  | 

### Return type

[**QueryResponse**](QueryResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Query result. |  -  |
**409** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **query_schema**
> Dict[str, object] query_schema(db_id)

Introspect a mount's tables + live engine capabilities.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.rest import ApiException
from pprint import pprint

# Defining the host is optional and defaults to http://127.0.0.1:8002
# See configuration.py for a list of all supported configuration parameters.
configuration = grobase.Configuration(
    host = "http://127.0.0.1:8002"
)

# The client must configure the authentication and authorization parameters
# in accordance with the API server security policy.
# Examples for each auth method are provided below, use the example that
# satisfies your auth use case.

# Configure API key authorization: apiKey
configuration.api_key['apiKey'] = os.environ["API_KEY"]

# Uncomment below to setup prefix (e.g. Bearer) for API key, if needed
# configuration.api_key_prefix['apiKey'] = 'Bearer'

# Configure Bearer authorization (JWT): bearerAuth
configuration = grobase.Configuration(
    access_token = os.environ["BEARER_TOKEN"]
)

# Enter a context with an instance of the API client
with grobase.ApiClient(configuration) as api_client:
    # Create an instance of the API class
    api_instance = grobase.QueryApi(api_client)
    db_id = 'db_id_example' # str | 

    try:
        # Introspect a mount's tables + live engine capabilities.
        api_response = api_instance.query_schema(db_id)
        print("The response of QueryApi->query_schema:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling QueryApi->query_schema: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **db_id** | **str**|  | 

### Return type

**Dict[str, object]**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Normalized schema. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **query_schema_ddl**
> query_schema_ddl(db_id, request_body)

Apply ONE schema-DDL operation to a mount.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.rest import ApiException
from pprint import pprint

# Defining the host is optional and defaults to http://127.0.0.1:8002
# See configuration.py for a list of all supported configuration parameters.
configuration = grobase.Configuration(
    host = "http://127.0.0.1:8002"
)

# The client must configure the authentication and authorization parameters
# in accordance with the API server security policy.
# Examples for each auth method are provided below, use the example that
# satisfies your auth use case.

# Configure API key authorization: apiKey
configuration.api_key['apiKey'] = os.environ["API_KEY"]

# Uncomment below to setup prefix (e.g. Bearer) for API key, if needed
# configuration.api_key_prefix['apiKey'] = 'Bearer'

# Configure Bearer authorization (JWT): bearerAuth
configuration = grobase.Configuration(
    access_token = os.environ["BEARER_TOKEN"]
)

# Enter a context with an instance of the API client
with grobase.ApiClient(configuration) as api_client:
    # Create an instance of the API class
    api_instance = grobase.QueryApi(api_client)
    db_id = 'db_id_example' # str | 
    request_body = None # Dict[str, object] | 

    try:
        # Apply ONE schema-DDL operation to a mount.
        api_instance.query_schema_ddl(db_id, request_body)
    except Exception as e:
        print("Exception when calling QueryApi->query_schema_ddl: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **db_id** | **str**|  | 
 **request_body** | [**Dict[str, object]**](object.md)|  | 

### Return type

void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: Not defined

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Applied. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **query_txn**
> TxnResponse query_txn(txn_request)

Single-mount atomic write batch (all-or-nothing).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.txn_request import TxnRequest
from grobase.models.txn_response import TxnResponse
from grobase.rest import ApiException
from pprint import pprint

# Defining the host is optional and defaults to http://127.0.0.1:8002
# See configuration.py for a list of all supported configuration parameters.
configuration = grobase.Configuration(
    host = "http://127.0.0.1:8002"
)

# The client must configure the authentication and authorization parameters
# in accordance with the API server security policy.
# Examples for each auth method are provided below, use the example that
# satisfies your auth use case.

# Configure API key authorization: apiKey
configuration.api_key['apiKey'] = os.environ["API_KEY"]

# Uncomment below to setup prefix (e.g. Bearer) for API key, if needed
# configuration.api_key_prefix['apiKey'] = 'Bearer'

# Configure Bearer authorization (JWT): bearerAuth
configuration = grobase.Configuration(
    access_token = os.environ["BEARER_TOKEN"]
)

# Enter a context with an instance of the API client
with grobase.ApiClient(configuration) as api_client:
    # Create an instance of the API class
    api_instance = grobase.QueryApi(api_client)
    txn_request = grobase.TxnRequest() # TxnRequest | 

    try:
        # Single-mount atomic write batch (all-or-nothing).
        api_response = api_instance.query_txn(txn_request)
        print("The response of QueryApi->query_txn:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling QueryApi->query_txn: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **txn_request** | [**TxnRequest**](TxnRequest.md)|  | 

### Return type

[**TxnResponse**](TxnResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Atomic result. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

