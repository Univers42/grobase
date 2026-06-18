//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;


class AuthApi {
  AuthApi([ApiClient? apiClient]) : apiClient = apiClient ?? defaultApiClient;

  final ApiClient apiClient;

  /// Begin a social/OIDC OAuth flow (302 to the provider).
  ///
  /// The SDK's `auth.signInWithOAuth()` builds this URL; the browser is redirected here, gotrue 302s to the provider, then back to `redirect_to`.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] provider (required):
  ///
  /// * [String] redirectTo:
  ///
  /// * [String] scopes:
  Future<Response> authAuthorizeWithHttpInfo(String provider, { String? redirectTo, String? scopes, Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/authorize';

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

      queryParams.addAll(_queryParams('', 'provider', provider));
    if (redirectTo != null) {
      queryParams.addAll(_queryParams('', 'redirect_to', redirectTo));
    }
    if (scopes != null) {
      queryParams.addAll(_queryParams('', 'scopes', scopes));
    }

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'GET',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Begin a social/OIDC OAuth flow (302 to the provider).
  ///
  /// The SDK's `auth.signInWithOAuth()` builds this URL; the browser is redirected here, gotrue 302s to the provider, then back to `redirect_to`.
  ///
  /// Parameters:
  ///
  /// * [String] provider (required):
  ///
  /// * [String] redirectTo:
  ///
  /// * [String] scopes:
  Future<void> authAuthorize(String provider, { String? redirectTo, String? scopes, Future<void>? abortTrigger, }) async {
    final response = await authAuthorizeWithHttpInfo(provider, redirectTo: redirectTo, scopes: scopes, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Get the authenticated user.
  ///
  /// Note: This method returns the HTTP [Response].
  Future<Response> authGetUserWithHttpInfo({ Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/user';

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'GET',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Get the authenticated user.
  Future<User?> authGetUser({ Future<void>? abortTrigger, }) async {
    final response = await authGetUserWithHttpInfo(abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'User',) as User;
    
    }
    return null;
  }

  /// Revoke the current session.
  ///
  /// Note: This method returns the HTTP [Response].
  Future<Response> authLogoutWithHttpInfo({ Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/logout';

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Revoke the current session.
  Future<void> authLogout({ Future<void>? abortTrigger, }) async {
    final response = await authLogoutWithHttpInfo(abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Send a password-recovery email.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [AuthRecoverRequest] authRecoverRequest (required):
  Future<Response> authRecoverWithHttpInfo(AuthRecoverRequest authRecoverRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/recover';

    // ignore: prefer_final_locals
    Object? postBody = authRecoverRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Send a password-recovery email.
  ///
  /// Parameters:
  ///
  /// * [AuthRecoverRequest] authRecoverRequest (required):
  Future<void> authRecover(AuthRecoverRequest authRecoverRequest, { Future<void>? abortTrigger, }) async {
    final response = await authRecoverWithHttpInfo(authRecoverRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Register a new user (email + password).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [SignUpRequest] signUpRequest (required):
  Future<Response> authSignUpWithHttpInfo(SignUpRequest signUpRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/signup';

    // ignore: prefer_final_locals
    Object? postBody = signUpRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Register a new user (email + password).
  ///
  /// Parameters:
  ///
  /// * [SignUpRequest] signUpRequest (required):
  Future<AuthSignUp200Response?> authSignUp(SignUpRequest signUpRequest, { Future<void>? abortTrigger, }) async {
    final response = await authSignUpWithHttpInfo(signUpRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'AuthSignUp200Response',) as AuthSignUp200Response;
    
    }
    return null;
  }

  /// Exchange credentials for a session (password or refresh_token grant).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] grantType (required):
  ///
  /// * [TokenRequest] tokenRequest (required):
  Future<Response> authTokenWithHttpInfo(String grantType, TokenRequest tokenRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/token';

    // ignore: prefer_final_locals
    Object? postBody = tokenRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

      queryParams.addAll(_queryParams('', 'grant_type', grantType));

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Exchange credentials for a session (password or refresh_token grant).
  ///
  /// Parameters:
  ///
  /// * [String] grantType (required):
  ///
  /// * [TokenRequest] tokenRequest (required):
  Future<Session?> authToken(String grantType, TokenRequest tokenRequest, { Future<void>? abortTrigger, }) async {
    final response = await authTokenWithHttpInfo(grantType, tokenRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'Session',) as Session;
    
    }
    return null;
  }

  /// Update the authenticated user (email / password / metadata).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [UpdateUserRequest] updateUserRequest (required):
  Future<Response> authUpdateUserWithHttpInfo(UpdateUserRequest updateUserRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/user';

    // ignore: prefer_final_locals
    Object? postBody = updateUserRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Update the authenticated user (email / password / metadata).
  ///
  /// Parameters:
  ///
  /// * [UpdateUserRequest] updateUserRequest (required):
  Future<User?> authUpdateUser(UpdateUserRequest updateUserRequest, { Future<void>? abortTrigger, }) async {
    final response = await authUpdateUserWithHttpInfo(updateUserRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'User',) as User;
    
    }
    return null;
  }

  /// Verify a signup/recovery/magiclink token.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [VerifyRequest] verifyRequest (required):
  Future<Response> authVerifyWithHttpInfo(VerifyRequest verifyRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/verify';

    // ignore: prefer_final_locals
    Object? postBody = verifyRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Verify a signup/recovery/magiclink token.
  ///
  /// Parameters:
  ///
  /// * [VerifyRequest] verifyRequest (required):
  Future<AuthSignUp200Response?> authVerify(VerifyRequest verifyRequest, { Future<void>? abortTrigger, }) async {
    final response = await authVerifyWithHttpInfo(verifyRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'AuthSignUp200Response',) as AuthSignUp200Response;
    
    }
    return null;
  }

  /// Open a verification challenge for an enrolled factor.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] factorId (required):
  Future<Response> mfaChallengeWithHttpInfo(String factorId, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/factors/{factorId}/challenge'
      .replaceAll('{factorId}', factorId);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Open a verification challenge for an enrolled factor.
  ///
  /// Parameters:
  ///
  /// * [String] factorId (required):
  Future<MfaChallengeResponse?> mfaChallenge(String factorId, { Future<void>? abortTrigger, }) async {
    final response = await mfaChallengeWithHttpInfo(factorId, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'MfaChallengeResponse',) as MfaChallengeResponse;
    
    }
    return null;
  }

  /// Enroll an MFA factor (TOTP or phone).
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [MfaEnrollRequest] mfaEnrollRequest (required):
  Future<Response> mfaEnrollWithHttpInfo(MfaEnrollRequest mfaEnrollRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/factors';

    // ignore: prefer_final_locals
    Object? postBody = mfaEnrollRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Enroll an MFA factor (TOTP or phone).
  ///
  /// Parameters:
  ///
  /// * [MfaEnrollRequest] mfaEnrollRequest (required):
  Future<MfaEnrollResponse?> mfaEnroll(MfaEnrollRequest mfaEnrollRequest, { Future<void>? abortTrigger, }) async {
    final response = await mfaEnrollWithHttpInfo(mfaEnrollRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'MfaEnrollResponse',) as MfaEnrollResponse;
    
    }
    return null;
  }

  /// Remove an MFA factor.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] factorId (required):
  Future<Response> mfaUnenrollWithHttpInfo(String factorId, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/factors/{factorId}'
      .replaceAll('{factorId}', factorId);

    // ignore: prefer_final_locals
    Object? postBody;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>[];


    return apiClient.invokeAPI(
      path,
      'DELETE',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Remove an MFA factor.
  ///
  /// Parameters:
  ///
  /// * [String] factorId (required):
  Future<void> mfaUnenroll(String factorId, { Future<void>? abortTrigger, }) async {
    final response = await mfaUnenrollWithHttpInfo(factorId, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
  }

  /// Verify a challenge with a code; on success upgrades the session AAL.
  ///
  /// Note: This method returns the HTTP [Response].
  ///
  /// Parameters:
  ///
  /// * [String] factorId (required):
  ///
  /// * [MfaVerifyRequest] mfaVerifyRequest (required):
  Future<Response> mfaVerifyWithHttpInfo(String factorId, MfaVerifyRequest mfaVerifyRequest, { Future<void>? abortTrigger, }) async {
    // ignore: prefer_const_declarations
    final path = r'/auth/v1/factors/{factorId}/verify'
      .replaceAll('{factorId}', factorId);

    // ignore: prefer_final_locals
    Object? postBody = mfaVerifyRequest;

    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{};
    final formParams = <String, String>{};

    const contentTypes = <String>['application/json'];


    return apiClient.invokeAPI(
      path,
      'POST',
      queryParams,
      postBody,
      headerParams,
      formParams,
      contentTypes.isEmpty ? null : contentTypes.first,
      abortTrigger: abortTrigger,
    );
  }

  /// Verify a challenge with a code; on success upgrades the session AAL.
  ///
  /// Parameters:
  ///
  /// * [String] factorId (required):
  ///
  /// * [MfaVerifyRequest] mfaVerifyRequest (required):
  Future<Session?> mfaVerify(String factorId, MfaVerifyRequest mfaVerifyRequest, { Future<void>? abortTrigger, }) async {
    final response = await mfaVerifyWithHttpInfo(factorId, mfaVerifyRequest, abortTrigger: abortTrigger,);
    if (response.statusCode >= HttpStatus.badRequest) {
      throw ApiException(response.statusCode, await _decodeBodyBytes(response));
    }
    // When a remote server returns no body with a status of 204, we shall not decode it.
    // At the time of writing this, `dart:convert` will throw an "Unexpected end of input"
    // FormatException when trying to decode an empty string.
    if (response.body.isNotEmpty && response.statusCode != HttpStatus.noContent) {
      return await apiClient.deserializeAsync(await _decodeBodyBytes(response), 'Session',) as Session;
    
    }
    return null;
  }
}
