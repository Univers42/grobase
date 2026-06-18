//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

import 'package:grobase/api.dart';
import 'package:test/test.dart';


/// tests for AuthApi
void main() {
  // final instance = AuthApi();

  group('tests for AuthApi', () {
    // Begin a social/OIDC OAuth flow (302 to the provider).
    //
    // The SDK's `auth.signInWithOAuth()` builds this URL; the browser is redirected here, gotrue 302s to the provider, then back to `redirect_to`.
    //
    //Future authAuthorize(String provider, { String redirectTo, String scopes }) async
    test('test authAuthorize', () async {
      // TODO
    });

    // Get the authenticated user.
    //
    //Future<User> authGetUser() async
    test('test authGetUser', () async {
      // TODO
    });

    // Revoke the current session.
    //
    //Future authLogout() async
    test('test authLogout', () async {
      // TODO
    });

    // Send a password-recovery email.
    //
    //Future authRecover(AuthRecoverRequest authRecoverRequest) async
    test('test authRecover', () async {
      // TODO
    });

    // Register a new user (email + password).
    //
    //Future<AuthSignUp200Response> authSignUp(SignUpRequest signUpRequest) async
    test('test authSignUp', () async {
      // TODO
    });

    // Exchange credentials for a session (password or refresh_token grant).
    //
    //Future<Session> authToken(String grantType, TokenRequest tokenRequest) async
    test('test authToken', () async {
      // TODO
    });

    // Update the authenticated user (email / password / metadata).
    //
    //Future<User> authUpdateUser(UpdateUserRequest updateUserRequest) async
    test('test authUpdateUser', () async {
      // TODO
    });

    // Verify a signup/recovery/magiclink token.
    //
    //Future<AuthSignUp200Response> authVerify(VerifyRequest verifyRequest) async
    test('test authVerify', () async {
      // TODO
    });

    // Open a verification challenge for an enrolled factor.
    //
    //Future<MfaChallengeResponse> mfaChallenge(String factorId) async
    test('test mfaChallenge', () async {
      // TODO
    });

    // Enroll an MFA factor (TOTP or phone).
    //
    //Future<MfaEnrollResponse> mfaEnroll(MfaEnrollRequest mfaEnrollRequest) async
    test('test mfaEnroll', () async {
      // TODO
    });

    // Remove an MFA factor.
    //
    //Future mfaUnenroll(String factorId) async
    test('test mfaUnenroll', () async {
      // TODO
    });

    // Verify a challenge with a code; on success upgrades the session AAL.
    //
    //Future<Session> mfaVerify(String factorId, MfaVerifyRequest mfaVerifyRequest) async
    test('test mfaVerify', () async {
      // TODO
    });

  });
}
