//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class AuthSignUp200Response {
  /// Returns a new [AuthSignUp200Response] instance.
  AuthSignUp200Response({
    required this.accessToken,
    this.tokenType,
    this.expiresIn,
    this.expiresAt,
    this.refreshToken,
    this.user,
    required this.id,
    this.email,
    this.role,
    this.aud,
    this.appMetadata = const {},
    this.userMetadata = const {},
    this.createdAt,
  });

  String accessToken;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? tokenType;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  int? expiresIn;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  int? expiresAt;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? refreshToken;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  User? user;

  String id;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? email;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? role;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? aud;

  Map<String, Object> appMetadata;

  Map<String, Object> userMetadata;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  DateTime? createdAt;

  @override
  bool operator ==(Object other) => identical(this, other) || other is AuthSignUp200Response &&
    other.accessToken == accessToken &&
    other.tokenType == tokenType &&
    other.expiresIn == expiresIn &&
    other.expiresAt == expiresAt &&
    other.refreshToken == refreshToken &&
    other.user == user &&
    other.id == id &&
    other.email == email &&
    other.role == role &&
    other.aud == aud &&
    _deepEquality.equals(other.appMetadata, appMetadata) &&
    _deepEquality.equals(other.userMetadata, userMetadata) &&
    other.createdAt == createdAt;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (accessToken.hashCode) +
    (tokenType == null ? 0 : tokenType!.hashCode) +
    (expiresIn == null ? 0 : expiresIn!.hashCode) +
    (expiresAt == null ? 0 : expiresAt!.hashCode) +
    (refreshToken == null ? 0 : refreshToken!.hashCode) +
    (user == null ? 0 : user!.hashCode) +
    (id.hashCode) +
    (email == null ? 0 : email!.hashCode) +
    (role == null ? 0 : role!.hashCode) +
    (aud == null ? 0 : aud!.hashCode) +
    (appMetadata.hashCode) +
    (userMetadata.hashCode) +
    (createdAt == null ? 0 : createdAt!.hashCode);

  @override
  String toString() => 'AuthSignUp200Response[accessToken=$accessToken, tokenType=$tokenType, expiresIn=$expiresIn, expiresAt=$expiresAt, refreshToken=$refreshToken, user=$user, id=$id, email=$email, role=$role, aud=$aud, appMetadata=$appMetadata, userMetadata=$userMetadata, createdAt=$createdAt]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'access_token'] = this.accessToken;
    if (this.tokenType != null) {
      json[r'token_type'] = this.tokenType;
    } else {
      json[r'token_type'] = null;
    }
    if (this.expiresIn != null) {
      json[r'expires_in'] = this.expiresIn;
    } else {
      json[r'expires_in'] = null;
    }
    if (this.expiresAt != null) {
      json[r'expires_at'] = this.expiresAt;
    } else {
      json[r'expires_at'] = null;
    }
    if (this.refreshToken != null) {
      json[r'refresh_token'] = this.refreshToken;
    } else {
      json[r'refresh_token'] = null;
    }
    if (this.user != null) {
      json[r'user'] = this.user;
    } else {
      json[r'user'] = null;
    }
      json[r'id'] = this.id;
    if (this.email != null) {
      json[r'email'] = this.email;
    } else {
      json[r'email'] = null;
    }
    if (this.role != null) {
      json[r'role'] = this.role;
    } else {
      json[r'role'] = null;
    }
    if (this.aud != null) {
      json[r'aud'] = this.aud;
    } else {
      json[r'aud'] = null;
    }
      json[r'app_metadata'] = this.appMetadata;
      json[r'user_metadata'] = this.userMetadata;
    if (this.createdAt != null) {
      json[r'created_at'] = this.createdAt!.toUtc().toIso8601String();
    } else {
      json[r'created_at'] = null;
    }
    return json;
  }

  /// Returns a new [AuthSignUp200Response] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static AuthSignUp200Response? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        assert(json.containsKey(r'access_token'), 'Required key "AuthSignUp200Response[access_token]" is missing from JSON.');
        assert(json[r'access_token'] != null, 'Required key "AuthSignUp200Response[access_token]" has a null value in JSON.');
        assert(json.containsKey(r'id'), 'Required key "AuthSignUp200Response[id]" is missing from JSON.');
        assert(json[r'id'] != null, 'Required key "AuthSignUp200Response[id]" has a null value in JSON.');
        return true;
      }());

      return AuthSignUp200Response(
        accessToken: mapValueOfType<String>(json, r'access_token')!,
        tokenType: mapValueOfType<String>(json, r'token_type'),
        expiresIn: mapValueOfType<int>(json, r'expires_in'),
        expiresAt: mapValueOfType<int>(json, r'expires_at'),
        refreshToken: mapValueOfType<String>(json, r'refresh_token'),
        user: User.fromJson(json[r'user']),
        id: mapValueOfType<String>(json, r'id')!,
        email: mapValueOfType<String>(json, r'email'),
        role: mapValueOfType<String>(json, r'role'),
        aud: mapValueOfType<String>(json, r'aud'),
        appMetadata: mapCastOfType<String, Object>(json, r'app_metadata') ?? const {},
        userMetadata: mapCastOfType<String, Object>(json, r'user_metadata') ?? const {},
        createdAt: mapDateTime(json, r'created_at', r''),
      );
    }
    return null;
  }

  static List<AuthSignUp200Response> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <AuthSignUp200Response>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = AuthSignUp200Response.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, AuthSignUp200Response> mapFromJson(dynamic json) {
    final map = <String, AuthSignUp200Response>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = AuthSignUp200Response.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of AuthSignUp200Response-objects as value to a dart map
  static Map<String, List<AuthSignUp200Response>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<AuthSignUp200Response>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = AuthSignUp200Response.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
    'access_token',
    'id',
  };
}

