# AuthAPI

All URIs are relative to *http://127.0.0.1:8002*

Method | HTTP request | Description
------------- | ------------- | -------------
[**authAuthorize**](AuthAPI.md#authauthorize) | **GET** /auth/v1/authorize | Begin a social/OIDC OAuth flow (302 to the provider).
[**authGetUser**](AuthAPI.md#authgetuser) | **GET** /auth/v1/user | Get the authenticated user.
[**authLogout**](AuthAPI.md#authlogout) | **POST** /auth/v1/logout | Revoke the current session.
[**authRecover**](AuthAPI.md#authrecover) | **POST** /auth/v1/recover | Send a password-recovery email.
[**authSignUp**](AuthAPI.md#authsignup) | **POST** /auth/v1/signup | Register a new user (email + password).
[**authToken**](AuthAPI.md#authtoken) | **POST** /auth/v1/token | Exchange credentials for a session (password or refresh_token grant).
[**authUpdateUser**](AuthAPI.md#authupdateuser) | **POST** /auth/v1/user | Update the authenticated user (email / password / metadata).
[**authVerify**](AuthAPI.md#authverify) | **POST** /auth/v1/verify | Verify a signup/recovery/magiclink token.
[**mfaChallenge**](AuthAPI.md#mfachallenge) | **POST** /auth/v1/factors/{factorId}/challenge | Open a verification challenge for an enrolled factor.
[**mfaEnroll**](AuthAPI.md#mfaenroll) | **POST** /auth/v1/factors | Enroll an MFA factor (TOTP or phone).
[**mfaUnenroll**](AuthAPI.md#mfaunenroll) | **DELETE** /auth/v1/factors/{factorId} | Remove an MFA factor.
[**mfaVerify**](AuthAPI.md#mfaverify) | **POST** /auth/v1/factors/{factorId}/verify | Verify a challenge with a code; on success upgrades the session AAL.


# **authAuthorize**
```swift
    open class func authAuthorize(provider: String, redirectTo: String? = nil, scopes: String? = nil, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Begin a social/OIDC OAuth flow (302 to the provider).

The SDK's `auth.signInWithOAuth()` builds this URL; the browser is redirected here, gotrue 302s to the provider, then back to `redirect_to`.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let provider = "provider_example" // String | 
let redirectTo = "redirectTo_example" // String |  (optional)
let scopes = "scopes_example" // String |  (optional)

// Begin a social/OIDC OAuth flow (302 to the provider).
AuthAPI.authAuthorize(provider: provider, redirectTo: redirectTo, scopes: scopes) { (response, error) in
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
 **provider** | **String** |  | 
 **redirectTo** | **String** |  | [optional] 
 **scopes** | **String** |  | [optional] 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authGetUser**
```swift
    open class func authGetUser(completion: @escaping (_ data: User?, _ error: Error?) -> Void)
```

Get the authenticated user.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase


// Get the authenticated user.
AuthAPI.authGetUser() { (response, error) in
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

[**User**](User.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authLogout**
```swift
    open class func authLogout(completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Revoke the current session.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase


// Revoke the current session.
AuthAPI.authLogout() { (response, error) in
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

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authRecover**
```swift
    open class func authRecover(authRecoverRequest: AuthRecoverRequest, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Send a password-recovery email.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let authRecoverRequest = authRecover_request(email: "email_example") // AuthRecoverRequest | 

// Send a password-recovery email.
AuthAPI.authRecover(authRecoverRequest: authRecoverRequest) { (response, error) in
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
 **authRecoverRequest** | [**AuthRecoverRequest**](AuthRecoverRequest.md) |  | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authSignUp**
```swift
    open class func authSignUp(signUpRequest: SignUpRequest, completion: @escaping (_ data: AuthSignUp200Response?, _ error: Error?) -> Void)
```

Register a new user (email + password).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let signUpRequest = SignUpRequest(email: "email_example", password: "password_example", data: "TODO") // SignUpRequest | 

// Register a new user (email + password).
AuthAPI.authSignUp(signUpRequest: signUpRequest) { (response, error) in
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
 **signUpRequest** | [**SignUpRequest**](SignUpRequest.md) |  | 

### Return type

[**AuthSignUp200Response**](AuthSignUp200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authToken**
```swift
    open class func authToken(grantType: GrantType_authToken, tokenRequest: TokenRequest, completion: @escaping (_ data: Session?, _ error: Error?) -> Void)
```

Exchange credentials for a session (password or refresh_token grant).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let grantType = "grantType_example" // String | 
let tokenRequest = TokenRequest(email: "email_example", password: "password_example", refreshToken: "refreshToken_example") // TokenRequest | 

// Exchange credentials for a session (password or refresh_token grant).
AuthAPI.authToken(grantType: grantType, tokenRequest: tokenRequest) { (response, error) in
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
 **grantType** | **String** |  | 
 **tokenRequest** | [**TokenRequest**](TokenRequest.md) |  | 

### Return type

[**Session**](Session.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authUpdateUser**
```swift
    open class func authUpdateUser(updateUserRequest: UpdateUserRequest, completion: @escaping (_ data: User?, _ error: Error?) -> Void)
```

Update the authenticated user (email / password / metadata).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let updateUserRequest = UpdateUserRequest(email: "email_example", password: "password_example", data: "TODO") // UpdateUserRequest | 

// Update the authenticated user (email / password / metadata).
AuthAPI.authUpdateUser(updateUserRequest: updateUserRequest) { (response, error) in
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
 **updateUserRequest** | [**UpdateUserRequest**](UpdateUserRequest.md) |  | 

### Return type

[**User**](User.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **authVerify**
```swift
    open class func authVerify(verifyRequest: VerifyRequest, completion: @escaping (_ data: AuthSignUp200Response?, _ error: Error?) -> Void)
```

Verify a signup/recovery/magiclink token.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let verifyRequest = VerifyRequest(type: "type_example", token: "token_example", tokenHash: "tokenHash_example") // VerifyRequest | 

// Verify a signup/recovery/magiclink token.
AuthAPI.authVerify(verifyRequest: verifyRequest) { (response, error) in
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
 **verifyRequest** | [**VerifyRequest**](VerifyRequest.md) |  | 

### Return type

[**AuthSignUp200Response**](AuthSignUp200Response.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfaChallenge**
```swift
    open class func mfaChallenge(factorId: String, completion: @escaping (_ data: MfaChallengeResponse?, _ error: Error?) -> Void)
```

Open a verification challenge for an enrolled factor.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let factorId = "factorId_example" // String | 

// Open a verification challenge for an enrolled factor.
AuthAPI.mfaChallenge(factorId: factorId) { (response, error) in
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
 **factorId** | **String** |  | 

### Return type

[**MfaChallengeResponse**](MfaChallengeResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfaEnroll**
```swift
    open class func mfaEnroll(mfaEnrollRequest: MfaEnrollRequest, completion: @escaping (_ data: MfaEnrollResponse?, _ error: Error?) -> Void)
```

Enroll an MFA factor (TOTP or phone).

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let mfaEnrollRequest = MfaEnrollRequest(factorType: "factorType_example", friendlyName: "friendlyName_example", issuer: "issuer_example", phone: "phone_example") // MfaEnrollRequest | 

// Enroll an MFA factor (TOTP or phone).
AuthAPI.mfaEnroll(mfaEnrollRequest: mfaEnrollRequest) { (response, error) in
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
 **mfaEnrollRequest** | [**MfaEnrollRequest**](MfaEnrollRequest.md) |  | 

### Return type

[**MfaEnrollResponse**](MfaEnrollResponse.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfaUnenroll**
```swift
    open class func mfaUnenroll(factorId: String, completion: @escaping (_ data: Void?, _ error: Error?) -> Void)
```

Remove an MFA factor.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let factorId = "factorId_example" // String | 

// Remove an MFA factor.
AuthAPI.mfaUnenroll(factorId: factorId) { (response, error) in
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
 **factorId** | **String** |  | 

### Return type

Void (empty response body)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: Not defined
 - **Accept**: Not defined

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

# **mfaVerify**
```swift
    open class func mfaVerify(factorId: String, mfaVerifyRequest: MfaVerifyRequest, completion: @escaping (_ data: Session?, _ error: Error?) -> Void)
```

Verify a challenge with a code; on success upgrades the session AAL.

### Example
```swift
// The following code samples are still beta. For any issue, please report via http://github.com/OpenAPITools/openapi-generator/issues/new
import Grobase

let factorId = "factorId_example" // String | 
let mfaVerifyRequest = MfaVerifyRequest(challengeId: "challengeId_example", code: "code_example") // MfaVerifyRequest | 

// Verify a challenge with a code; on success upgrades the session AAL.
AuthAPI.mfaVerify(factorId: factorId, mfaVerifyRequest: mfaVerifyRequest) { (response, error) in
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
 **factorId** | **String** |  | 
 **mfaVerifyRequest** | [**MfaVerifyRequest**](MfaVerifyRequest.md) |  | 

### Return type

[**Session**](Session.md)

### Authorization

[apiKey](../README.md#apiKey), [bearerAuth](../README.md#bearerAuth)

### HTTP request headers

 - **Content-Type**: application/json
 - **Accept**: application/json

[[Back to top]](#) [[Back to API list]](../README.md#documentation-for-api-endpoints) [[Back to Model list]](../README.md#documentation-for-models) [[Back to README]](../README.md)

