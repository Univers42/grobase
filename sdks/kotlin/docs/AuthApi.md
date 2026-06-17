# AuthApi

All URIs are relative to *http://127.0.0.1:8002*

| Method | HTTP request | Description |
| ------------- | ------------- | ------------- |
| [**authAuthorize**](AuthApi.md#authAuthorize) | **GET** /auth/v1/authorize | Begin a social/OIDC OAuth flow (302 to the provider). |
| [**authGetUser**](AuthApi.md#authGetUser) | **GET** /auth/v1/user | Get the authenticated user. |
| [**authLogout**](AuthApi.md#authLogout) | **POST** /auth/v1/logout | Revoke the current session. |
| [**authRecover**](AuthApi.md#authRecover) | **POST** /auth/v1/recover | Send a password-recovery email. |
| [**authSignUp**](AuthApi.md#authSignUp) | **POST** /auth/v1/signup | Register a new user (email + password). |
| [**authToken**](AuthApi.md#authToken) | **POST** /auth/v1/token | Exchange credentials for a session (password or refresh_token grant). |
| [**authUpdateUser**](AuthApi.md#authUpdateUser) | **POST** /auth/v1/user | Update the authenticated user (email / password / metadata). |
| [**authVerify**](AuthApi.md#authVerify) | **POST** /auth/v1/verify | Verify a signup/recovery/magiclink token. |
| [**mfaChallenge**](AuthApi.md#mfaChallenge) | **POST** /auth/v1/factors/{factorId}/challenge | Open a verification challenge for an enrolled factor. |
| [**mfaEnroll**](AuthApi.md#mfaEnroll) | **POST** /auth/v1/factors | Enroll an MFA factor (TOTP or phone). |
| [**mfaUnenroll**](AuthApi.md#mfaUnenroll) | **DELETE** /auth/v1/factors/{factorId} | Remove an MFA factor. |
| [**mfaVerify**](AuthApi.md#mfaVerify) | **POST** /auth/v1/factors/{factorId}/verify | Verify a challenge with a code; on success upgrades the session AAL. |


<a id="authAuthorize"></a>
# **authAuthorize**
> authAuthorize(provider, redirectTo, scopes)

Begin a social/OIDC OAuth flow (302 to the provider).

The SDK&#39;s &#x60;auth.signInWithOAuth()&#x60; builds this URL; the browser is redirected here, gotrue 302s to the provider, then back to &#x60;redirect_to&#x60;.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val provider : kotlin.String = provider_example // kotlin.String | 
val redirectTo : java.net.URI = redirectTo_example // java.net.URI | 
val scopes : kotlin.String = scopes_example // kotlin.String | 
try {
    apiInstance.authAuthorize(provider, redirectTo, scopes)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authAuthorize")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authAuthorize")
    e.printStackTrace()
}
```

### Parameters
| **provider** | **kotlin.String**|  | |
| **redirectTo** | **java.net.URI**|  | [optional] |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **scopes** | **kotlin.String**|  | [optional] |

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

<a id="authGetUser"></a>
# **authGetUser**
> User authGetUser()

Get the authenticated user.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
try {
    val result : User = apiInstance.authGetUser()
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authGetUser")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authGetUser")
    e.printStackTrace()
}
```

### Parameters
This endpoint does not need any parameter.

### Return type

[**User**](User.md)

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

<a id="authLogout"></a>
# **authLogout**
> authLogout()

Revoke the current session.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
try {
    apiInstance.authLogout()
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authLogout")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authLogout")
    e.printStackTrace()
}
```

### Parameters
This endpoint does not need any parameter.

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

<a id="authRecover"></a>
# **authRecover**
> authRecover(authRecoverRequest)

Send a password-recovery email.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val authRecoverRequest : AuthRecoverRequest =  // AuthRecoverRequest | 
try {
    apiInstance.authRecover(authRecoverRequest)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authRecover")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authRecover")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **authRecoverRequest** | [**AuthRecoverRequest**](AuthRecoverRequest.md)|  | |

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

<a id="authSignUp"></a>
# **authSignUp**
> AuthSignUp200Response authSignUp(signUpRequest)

Register a new user (email + password).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val signUpRequest : SignUpRequest =  // SignUpRequest | 
try {
    val result : AuthSignUp200Response = apiInstance.authSignUp(signUpRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authSignUp")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authSignUp")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **signUpRequest** | [**SignUpRequest**](SignUpRequest.md)|  | |

### Return type

[**AuthSignUp200Response**](AuthSignUp200Response.md)

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

<a id="authToken"></a>
# **authToken**
> Session authToken(grantType, tokenRequest)

Exchange credentials for a session (password or refresh_token grant).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val grantType : kotlin.String = grantType_example // kotlin.String | 
val tokenRequest : TokenRequest =  // TokenRequest | 
try {
    val result : Session = apiInstance.authToken(grantType, tokenRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authToken")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authToken")
    e.printStackTrace()
}
```

### Parameters
| **grantType** | **kotlin.String**|  | [enum: password, refresh_token] |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **tokenRequest** | [**TokenRequest**](TokenRequest.md)|  | |

### Return type

[**Session**](Session.md)

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

<a id="authUpdateUser"></a>
# **authUpdateUser**
> User authUpdateUser(updateUserRequest)

Update the authenticated user (email / password / metadata).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val updateUserRequest : UpdateUserRequest =  // UpdateUserRequest | 
try {
    val result : User = apiInstance.authUpdateUser(updateUserRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authUpdateUser")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authUpdateUser")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **updateUserRequest** | [**UpdateUserRequest**](UpdateUserRequest.md)|  | |

### Return type

[**User**](User.md)

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

<a id="authVerify"></a>
# **authVerify**
> AuthSignUp200Response authVerify(verifyRequest)

Verify a signup/recovery/magiclink token.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val verifyRequest : VerifyRequest =  // VerifyRequest | 
try {
    val result : AuthSignUp200Response = apiInstance.authVerify(verifyRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#authVerify")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#authVerify")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **verifyRequest** | [**VerifyRequest**](VerifyRequest.md)|  | |

### Return type

[**AuthSignUp200Response**](AuthSignUp200Response.md)

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

<a id="mfaChallenge"></a>
# **mfaChallenge**
> MfaChallengeResponse mfaChallenge(factorId)

Open a verification challenge for an enrolled factor.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val factorId : kotlin.String = factorId_example // kotlin.String | 
try {
    val result : MfaChallengeResponse = apiInstance.mfaChallenge(factorId)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#mfaChallenge")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#mfaChallenge")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **factorId** | **kotlin.String**|  | |

### Return type

[**MfaChallengeResponse**](MfaChallengeResponse.md)

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

<a id="mfaEnroll"></a>
# **mfaEnroll**
> MfaEnrollResponse mfaEnroll(mfaEnrollRequest)

Enroll an MFA factor (TOTP or phone).

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val mfaEnrollRequest : MfaEnrollRequest =  // MfaEnrollRequest | 
try {
    val result : MfaEnrollResponse = apiInstance.mfaEnroll(mfaEnrollRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#mfaEnroll")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#mfaEnroll")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **mfaEnrollRequest** | [**MfaEnrollRequest**](MfaEnrollRequest.md)|  | |

### Return type

[**MfaEnrollResponse**](MfaEnrollResponse.md)

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

<a id="mfaUnenroll"></a>
# **mfaUnenroll**
> mfaUnenroll(factorId)

Remove an MFA factor.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val factorId : kotlin.String = factorId_example // kotlin.String | 
try {
    apiInstance.mfaUnenroll(factorId)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#mfaUnenroll")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#mfaUnenroll")
    e.printStackTrace()
}
```

### Parameters
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **factorId** | **kotlin.String**|  | |

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

<a id="mfaVerify"></a>
# **mfaVerify**
> Session mfaVerify(factorId, mfaVerifyRequest)

Verify a challenge with a code; on success upgrades the session AAL.

### Example
```kotlin
// Import classes:
//import grobase.infrastructure.*
//import grobase.models.*

val apiInstance = AuthApi()
val factorId : kotlin.String = factorId_example // kotlin.String | 
val mfaVerifyRequest : MfaVerifyRequest =  // MfaVerifyRequest | 
try {
    val result : Session = apiInstance.mfaVerify(factorId, mfaVerifyRequest)
    println(result)
} catch (e: ClientException) {
    println("4xx response calling AuthApi#mfaVerify")
    e.printStackTrace()
} catch (e: ServerException) {
    println("5xx response calling AuthApi#mfaVerify")
    e.printStackTrace()
}
```

### Parameters
| **factorId** | **kotlin.String**|  | |
| Name | Type | Description  | Notes |
| ------------- | ------------- | ------------- | ------------- |
| **mfaVerifyRequest** | [**MfaVerifyRequest**](MfaVerifyRequest.md)|  | |

### Return type

[**Session**](Session.md)

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

