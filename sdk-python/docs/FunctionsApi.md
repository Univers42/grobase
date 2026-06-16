# grobase.FunctionsApi

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**function_delete**](FunctionsApi.md#function_delete) | **DELETE** /functions/v1/{name} | Delete a deployed function.
[**function_get**](FunctionsApi.md#function_get) | **GET** /functions/v1/{name} | Get a deployed function&#39;s source.
[**function_invoke**](FunctionsApi.md#function_invoke) | **POST** /functions/v1/{name}/invoke | Invoke a deployed edge function.


# **function_delete**
> function_delete(name)

Delete a deployed function.

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
    api_instance = grobase.FunctionsApi(api_client)
    name = 'name_example' # str | 

    try:
        # Delete a deployed function.
        api_instance.function_delete(name)
    except Exception as e:
        print("Exception when calling FunctionsApi->function_delete: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **name** | **str**|  | 

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
**200** | Deleted. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **function_get**
> FunctionGet200Response function_get(name)

Get a deployed function's source.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.function_get200_response import FunctionGet200Response
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
    api_instance = grobase.FunctionsApi(api_client)
    name = 'name_example' # str | 

    try:
        # Get a deployed function's source.
        api_response = api_instance.function_get(name)
        print("The response of FunctionsApi->function_get:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling FunctionsApi->function_get: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **name** | **str**|  | 

### Return type

[**FunctionGet200Response**](FunctionGet200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Source. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **function_invoke**
> function_invoke(name, request_body=request_body)

Invoke a deployed edge function.

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
    api_instance = grobase.FunctionsApi(api_client)
    name = 'name_example' # str | 
    request_body = None # Dict[str, object] |  (optional)

    try:
        # Invoke a deployed edge function.
        api_instance.function_invoke(name, request_body=request_body)
    except Exception as e:
        print("Exception when calling FunctionsApi->function_invoke: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **name** | **str**|  | 
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
**200** | Function output (passthrough). |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

