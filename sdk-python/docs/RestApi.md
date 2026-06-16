# grobase.RestApi

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**rest_delete**](RestApi.md#rest_delete) | **DELETE** /rest/v1/{resource} | Delete rows matching the filter.
[**rest_insert**](RestApi.md#rest_insert) | **POST** /rest/v1/{resource} | Insert one or many rows.
[**rest_rpc**](RestApi.md#rest_rpc) | **POST** /rest/v1/rpc/{fn} | Call a Postgres stored function (PostgREST RPC).
[**rest_select**](RestApi.md#rest_select) | **GET** /rest/v1/{resource} | Select rows (PostgREST filters via query params).
[**rest_update**](RestApi.md#rest_update) | **PATCH** /rest/v1/{resource} | Update rows matching the filter.


# **rest_delete**
> rest_delete(resource)

Delete rows matching the filter.

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
    api_instance = grobase.RestApi(api_client)
    resource = 'resource_example' # str | Table or view name.

    try:
        # Delete rows matching the filter.
        api_instance.rest_delete(resource)
    except Exception as e:
        print("Exception when calling RestApi->rest_delete: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **resource** | **str**| Table or view name. | 

### Return type

void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Deleted rows. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **rest_insert**
> rest_insert(resource, request_body)

Insert one or many rows.

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
    api_instance = grobase.RestApi(api_client)
    resource = 'resource_example' # str | Table or view name.
    request_body = None # Dict[str, object] | 

    try:
        # Insert one or many rows.
        api_instance.rest_insert(resource, request_body)
    except Exception as e:
        print("Exception when calling RestApi->rest_insert: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **resource** | **str**| Table or view name. | 
 **request_body** | [**Dict[str, object]**](object.md)|  | 

### Return type

void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**201** | Inserted rows (Prefer: return&#x3D;representation). |  -  |
**409** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **rest_rpc**
> rest_rpc(fn, request_body=request_body)

Call a Postgres stored function (PostgREST RPC).

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
    api_instance = grobase.RestApi(api_client)
    fn = 'fn_example' # str | 
    request_body = None # Dict[str, object] |  (optional)

    try:
        # Call a Postgres stored function (PostgREST RPC).
        api_instance.rest_rpc(fn, request_body=request_body)
    except Exception as e:
        print("Exception when calling RestApi->rest_rpc: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **fn** | **str**|  | 
 **request_body** | [**Dict[str, object]**](object.md)|  | [optional] 

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
**200** | Function result. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **rest_select**
> List[object] rest_select(resource, select=select, order=order, limit=limit, offset=offset)

Select rows (PostgREST filters via query params).

Filters are PostgREST `column=op.value` query params (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `is`, `in`), plus `select`, `order`, `limit`, `offset`, and `or`. Send `Accept: application/vnd.pgrst.object+json` for `.single()`.

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
    api_instance = grobase.RestApi(api_client)
    resource = 'resource_example' # str | Table or view name.
    select = 'select_example' # str |  (optional)
    order = 'order_example' # str |  (optional)
    limit = 56 # int |  (optional)
    offset = 56 # int |  (optional)

    try:
        # Select rows (PostgREST filters via query params).
        api_response = api_instance.rest_select(resource, select=select, order=order, limit=limit, offset=offset)
        print("The response of RestApi->rest_select:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling RestApi->rest_select: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **resource** | **str**| Table or view name. | 
 **select** | **str**|  | [optional] 
 **order** | **str**|  | [optional] 
 **limit** | **int**|  | [optional] 
 **offset** | **int**|  | [optional] 

### Return type

**List[object]**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Matching rows. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **rest_update**
> rest_update(resource, request_body)

Update rows matching the filter.

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
    api_instance = grobase.RestApi(api_client)
    resource = 'resource_example' # str | Table or view name.
    request_body = None # Dict[str, object] | 

    try:
        # Update rows matching the filter.
        api_instance.rest_update(resource, request_body)
    except Exception as e:
        print("Exception when calling RestApi->rest_update: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **resource** | **str**| Table or view name. | 
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
**200** | Updated rows. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

