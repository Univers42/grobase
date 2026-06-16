# grobase.AuthApi

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**auth_authorize**](AuthApi.md#auth_authorize) | **GET** /auth/v1/authorize | Begin a social/OIDC OAuth flow (302 to the provider).
[**auth_get_user**](AuthApi.md#auth_get_user) | **GET** /auth/v1/user | Get the authenticated user.
[**auth_logout**](AuthApi.md#auth_logout) | **POST** /auth/v1/logout | Revoke the current session.
[**auth_recover**](AuthApi.md#auth_recover) | **POST** /auth/v1/recover | Send a password-recovery email.
[**auth_sign_up**](AuthApi.md#auth_sign_up) | **POST** /auth/v1/signup | Register a new user (email + password).
[**auth_token**](AuthApi.md#auth_token) | **POST** /auth/v1/token | Exchange credentials for a session (password or refresh_token grant).
[**auth_update_user**](AuthApi.md#auth_update_user) | **POST** /auth/v1/user | Update the authenticated user (email / password / metadata).
[**auth_verify**](AuthApi.md#auth_verify) | **POST** /auth/v1/verify | Verify a signup/recovery/magiclink token.
[**mfa_challenge**](AuthApi.md#mfa_challenge) | **POST** /auth/v1/factors/{factorId}/challenge | Open a verification challenge for an enrolled factor.
[**mfa_enroll**](AuthApi.md#mfa_enroll) | **POST** /auth/v1/factors | Enroll an MFA factor (TOTP or phone).
[**mfa_unenroll**](AuthApi.md#mfa_unenroll) | **DELETE** /auth/v1/factors/{factorId} | Remove an MFA factor.
[**mfa_verify**](AuthApi.md#mfa_verify) | **POST** /auth/v1/factors/{factorId}/verify | Verify a challenge with a code; on success upgrades the session AAL.


# **auth_authorize**
> auth_authorize(provider, redirect_to=redirect_to, scopes=scopes)

Begin a social/OIDC OAuth flow (302 to the provider).

The SDK's `auth.signInWithOAuth()` builds this URL; the browser is redirected here, gotrue 302s to the provider, then back to `redirect_to`.

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
    api_instance = grobase.AuthApi(api_client)
    provider = 'provider_example' # str | 
    redirect_to = 'redirect_to_example' # str |  (optional)
    scopes = 'scopes_example' # str |  (optional)

    try:
        # Begin a social/OIDC OAuth flow (302 to the provider).
        api_instance.auth_authorize(provider, redirect_to=redirect_to, scopes=scopes)
    except Exception as e:
        print("Exception when calling AuthApi->auth_authorize: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **provider** | **str**|  | 
 **redirect_to** | **str**|  | [optional] 
 **scopes** | **str**|  | [optional] 

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
**302** | Redirect to the OAuth provider. |  * Location -  <br>  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_get_user**
> User auth_get_user()

Get the authenticated user.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.user import User
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
    api_instance = grobase.AuthApi(api_client)

    try:
        # Get the authenticated user.
        api_response = api_instance.auth_get_user()
        print("The response of AuthApi->auth_get_user:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->auth_get_user: %s\n" % e)
```



### Parameters

This endpoint does not need any parameter.

### Return type

[**User**](User.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | User. |  -  |
**401** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_logout**
> auth_logout()

Revoke the current session.

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
    api_instance = grobase.AuthApi(api_client)

    try:
        # Revoke the current session.
        api_instance.auth_logout()
    except Exception as e:
        print("Exception when calling AuthApi->auth_logout: %s\n" % e)
```



### Parameters

This endpoint does not need any parameter.

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
**204** | Logged out. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_recover**
> auth_recover(auth_recover_request)

Send a password-recovery email.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.auth_recover_request import AuthRecoverRequest
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
    api_instance = grobase.AuthApi(api_client)
    auth_recover_request = grobase.AuthRecoverRequest() # AuthRecoverRequest | 

    try:
        # Send a password-recovery email.
        api_instance.auth_recover(auth_recover_request)
    except Exception as e:
        print("Exception when calling AuthApi->auth_recover: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **auth_recover_request** | [**AuthRecoverRequest**](AuthRecoverRequest.md)|  | 

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
**200** | Accepted. |  -  |
**400** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_sign_up**
> AuthSignUp200Response auth_sign_up(sign_up_request)

Register a new user (email + password).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.auth_sign_up200_response import AuthSignUp200Response
from grobase.models.sign_up_request import SignUpRequest
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
    api_instance = grobase.AuthApi(api_client)
    sign_up_request = grobase.SignUpRequest() # SignUpRequest | 

    try:
        # Register a new user (email + password).
        api_response = api_instance.auth_sign_up(sign_up_request)
        print("The response of AuthApi->auth_sign_up:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->auth_sign_up: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **sign_up_request** | [**SignUpRequest**](SignUpRequest.md)|  | 

### Return type

[**AuthSignUp200Response**](AuthSignUp200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Session or pending user. |  -  |
**400** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_token**
> Session auth_token(grant_type, token_request)

Exchange credentials for a session (password or refresh_token grant).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.session import Session
from grobase.models.token_request import TokenRequest
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
    api_instance = grobase.AuthApi(api_client)
    grant_type = 'grant_type_example' # str | 
    token_request = grobase.TokenRequest() # TokenRequest | 

    try:
        # Exchange credentials for a session (password or refresh_token grant).
        api_response = api_instance.auth_token(grant_type, token_request)
        print("The response of AuthApi->auth_token:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->auth_token: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **grant_type** | **str**|  | 
 **token_request** | [**TokenRequest**](TokenRequest.md)|  | 

### Return type

[**Session**](Session.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Session. |  -  |
**400** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_update_user**
> User auth_update_user(update_user_request)

Update the authenticated user (email / password / metadata).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.update_user_request import UpdateUserRequest
from grobase.models.user import User
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
    api_instance = grobase.AuthApi(api_client)
    update_user_request = grobase.UpdateUserRequest() # UpdateUserRequest | 

    try:
        # Update the authenticated user (email / password / metadata).
        api_response = api_instance.auth_update_user(update_user_request)
        print("The response of AuthApi->auth_update_user:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->auth_update_user: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **update_user_request** | [**UpdateUserRequest**](UpdateUserRequest.md)|  | 

### Return type

[**User**](User.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | User. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **auth_verify**
> AuthSignUp200Response auth_verify(verify_request)

Verify a signup/recovery/magiclink token.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.auth_sign_up200_response import AuthSignUp200Response
from grobase.models.verify_request import VerifyRequest
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
    api_instance = grobase.AuthApi(api_client)
    verify_request = grobase.VerifyRequest() # VerifyRequest | 

    try:
        # Verify a signup/recovery/magiclink token.
        api_response = api_instance.auth_verify(verify_request)
        print("The response of AuthApi->auth_verify:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->auth_verify: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **verify_request** | [**VerifyRequest**](VerifyRequest.md)|  | 

### Return type

[**AuthSignUp200Response**](AuthSignUp200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Session or user. |  -  |
**400** | Error envelope. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfa_challenge**
> MfaChallengeResponse mfa_challenge(factor_id)

Open a verification challenge for an enrolled factor.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.mfa_challenge_response import MfaChallengeResponse
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
    api_instance = grobase.AuthApi(api_client)
    factor_id = 'factor_id_example' # str | 

    try:
        # Open a verification challenge for an enrolled factor.
        api_response = api_instance.mfa_challenge(factor_id)
        print("The response of AuthApi->mfa_challenge:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->mfa_challenge: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **factor_id** | **str**|  | 

### Return type

[**MfaChallengeResponse**](MfaChallengeResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Challenge. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfa_enroll**
> MfaEnrollResponse mfa_enroll(mfa_enroll_request)

Enroll an MFA factor (TOTP or phone).

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.mfa_enroll_request import MfaEnrollRequest
from grobase.models.mfa_enroll_response import MfaEnrollResponse
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
    api_instance = grobase.AuthApi(api_client)
    mfa_enroll_request = grobase.MfaEnrollRequest() # MfaEnrollRequest | 

    try:
        # Enroll an MFA factor (TOTP or phone).
        api_response = api_instance.mfa_enroll(mfa_enroll_request)
        print("The response of AuthApi->mfa_enroll:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->mfa_enroll: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **mfa_enroll_request** | [**MfaEnrollRequest**](MfaEnrollRequest.md)|  | 

### Return type

[**MfaEnrollResponse**](MfaEnrollResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Enrolled factor. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfa_unenroll**
> mfa_unenroll(factor_id)

Remove an MFA factor.

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
    api_instance = grobase.AuthApi(api_client)
    factor_id = 'factor_id_example' # str | 

    try:
        # Remove an MFA factor.
        api_instance.mfa_unenroll(factor_id)
    except Exception as e:
        print("Exception when calling AuthApi->mfa_unenroll: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **factor_id** | **str**|  | 

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
**200** | Removed. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfa_verify**
> Session mfa_verify(factor_id, mfa_verify_request)

Verify a challenge with a code; on success upgrades the session AAL.

### Example

* Api Key Authentication (apiKey):
* Bearer (JWT) Authentication (bearerAuth):

```python
import grobase
from grobase.models.mfa_verify_request import MfaVerifyRequest
from grobase.models.session import Session
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
    api_instance = grobase.AuthApi(api_client)
    factor_id = 'factor_id_example' # str | 
    mfa_verify_request = grobase.MfaVerifyRequest() # MfaVerifyRequest | 

    try:
        # Verify a challenge with a code; on success upgrades the session AAL.
        api_response = api_instance.mfa_verify(factor_id, mfa_verify_request)
        print("The response of AuthApi->mfa_verify:\n")
        pprint(api_response)
    except Exception as e:
        print("Exception when calling AuthApi->mfa_verify: %s\n" % e)
```



### Parameters


Name | Type | Description  | Notes
------------- | ------------- | ------------- | -------------
 **factor_id** | **str**|  | 
 **mfa_verify_request** | [**MfaVerifyRequest**](MfaVerifyRequest.md)|  | 

### Return type

[**Session**](Session.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

### HTTP response details

| Status code | Description | Response headers |
|-------------|-------------|------------------|
**200** | Upgraded session. |  -  |

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

