# grobase.StorageApi

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**storage_create_bucket**](StorageApi.md#storage_create_bucket) | **POST** /storage/v1/bucket/{name} | Create a bucket.
[**storage_delete**](StorageApi.md#storage_delete) | **DELETE** /storage/v1/object/{bucket}/{key} | Delete an object.
[**storage_download**](StorageApi.md#storage_download) | **GET** /storage/v1/object/{bucket}/{key} | Download object bytes (owner-scoped).
[**storage_list**](StorageApi.md#storage_list) | **GET** /storage/v1/list/{bucket} | List objects under a prefix (owner-scoped).
[**storage_list_buckets**](StorageApi.md#storage_list_buckets) | **GET** /storage/v1/bucket | List buckets.
[**storage_sign**](StorageApi.md#storage_sign) | **POST** /storage/v1/sign/{bucket}/{key} | Create a presigned URL (PUT or GET, TTL-clamped).
[**storage_upload**](StorageApi.md#storage_upload) | **PUT** /storage/v1/object/{bucket}/{key} | Upload (owner-prefixed) — body is the raw object bytes.


# **storage_create_bucket**
> StorageCreateBucket200Response storage_create_bucket(name)

Create a bucket.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.storage_create_bucket200_response import StorageCreateBucket200Response
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
    api_instance = grobase.StorageApi(api_client)
    name = 'name_example' # str | 

    try:
        # Create a bucket.
        api_response = api_instance.storage_create_bucket(name)
        print("The response of StorageApi->storage_create_bucket:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling StorageApi->storage_create_bucket: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **name** | **str**|  | 

### Return type

[**StorageCreateBucket200Response**](StorageCreateBucket200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Created. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storage_delete**
> storage_delete(bucket, key)

Delete an object.

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
    api_instance = grobase.StorageApi(api_client)
    bucket = 'bucket_example' # str | 
    key = 'key_example' # str | 

    try:
        # Delete an object.
        api_instance.storage_delete(bucket, key)
    except Exception as e:
        print("Exception when calling StorageApi->storage_delete: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **str**|  | 
 **key** | **str**|  | 

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

# **storage_download**
> bytes storage_download(bucket, key)

Download object bytes (owner-scoped).

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
    api_instance = grobase.StorageApi(api_client)
    bucket = 'bucket_example' # str | 
    key = 'key_example' # str | 

    try:
        # Download object bytes (owner-scoped).
        api_response = api_instance.storage_download(bucket, key)
        print("The response of StorageApi->storage_download:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling StorageApi->storage_download: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **str**|  | 
 **key** | **str**|  | 

### Return type

**bytes**

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/octet-stream, application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Object bytes. |  -  |
**404** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storage_list**
> StorageList200Response storage_list(bucket, prefix=prefix)

List objects under a prefix (owner-scoped).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.storage_list200_response import StorageList200Response
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
    api_instance = grobase.StorageApi(api_client)
    bucket = 'bucket_example' # str | 
    prefix = 'prefix_example' # str |  (optional)

    try:
        # List objects under a prefix (owner-scoped).
        api_response = api_instance.storage_list(bucket, prefix=prefix)
        print("The response of StorageApi->storage_list:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling StorageApi->storage_list: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **str**|  | 
 **prefix** | **str**|  | [optional] 

### Return type

[**StorageList200Response**](StorageList200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Objects. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storage_list_buckets**
> StorageListBuckets200Response storage_list_buckets()

List buckets.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.storage_list_buckets200_response import StorageListBuckets200Response
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
    api_instance = grobase.StorageApi(api_client)

    try:
        # List buckets.
        api_response = api_instance.storage_list_buckets()
        print("The response of StorageApi->storage_list_buckets:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling StorageApi->storage_list_buckets: %s\n" % e)
```



### Parameters

This endpoint does not need any parameter.

### Return type

[**StorageListBuckets200Response**](StorageListBuckets200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Buckets. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storage_sign**
> SignedUrl storage_sign(bucket, key, storage_sign_request=storage_sign_request)

Create a presigned URL (PUT or GET, TTL-clamped).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.signed_url import SignedUrl
from grobase.models.storage_sign_request import StorageSignRequest
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
    api_instance = grobase.StorageApi(api_client)
    bucket = 'bucket_example' # str | 
    key = 'key_example' # str | 
    storage_sign_request = grobase.StorageSignRequest() # StorageSignRequest |  (optional)

    try:
        # Create a presigned URL (PUT or GET, TTL-clamped).
        api_response = api_instance.storage_sign(bucket, key, storage_sign_request=storage_sign_request)
        print("The response of StorageApi->storage_sign:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling StorageApi->storage_sign: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **str**|  | 
 **key** | **str**|  | 
 **storage_sign_request** | [**StorageSignRequest**](StorageSignRequest.md)|  | [optional] 

### Return type

[**SignedUrl**](SignedUrl.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Signed URL. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **storage_upload**
> UploadResult storage_upload(bucket, key, body)

Upload (owner-prefixed) — body is the raw object bytes.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.upload_result import UploadResult
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
    api_instance = grobase.StorageApi(api_client)
    bucket = 'bucket_example' # str | 
    key = 'key_example' # str | 
    body = None # bytes | 

    try:
        # Upload (owner-prefixed) — body is the raw object bytes.
        api_response = api_instance.storage_upload(bucket, key, body)
        print("The response of StorageApi->storage_upload:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling StorageApi->storage_upload: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **bucket** | **str**|  | 
 **key** | **str**|  | 
 **body** | **bytes**|  | 

### Return type

[**UploadResult**](UploadResult.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/octet-stream
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Stored object. |  -  |
**413** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

