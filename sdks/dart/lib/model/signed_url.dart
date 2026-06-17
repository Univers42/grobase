//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class SignedUrl {
  /// Returns a new [SignedUrl] instance.
  SignedUrl({
    this.signedUrl,
    this.expiresAt,
    this.method,
    this.bucket,
    this.key,
  });

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? signedUrl;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? expiresAt;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? method;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? bucket;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? key;

  @override
  bool operator ==(Object other) => identical(this, other) || other is SignedUrl &&
    other.signedUrl == signedUrl &&
    other.expiresAt == expiresAt &&
    other.method == method &&
    other.bucket == bucket &&
    other.key == key;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (signedUrl == null ? 0 : signedUrl!.hashCode) +
    (expiresAt == null ? 0 : expiresAt!.hashCode) +
    (method == null ? 0 : method!.hashCode) +
    (bucket == null ? 0 : bucket!.hashCode) +
    (key == null ? 0 : key!.hashCode);

  @override
  String toString() => 'SignedUrl[signedUrl=$signedUrl, expiresAt=$expiresAt, method=$method, bucket=$bucket, key=$key]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (this.signedUrl != null) {
      json[r'signedUrl'] = this.signedUrl;
    } else {
      json[r'signedUrl'] = null;
    }
    if (this.expiresAt != null) {
      json[r'expiresAt'] = this.expiresAt;
    } else {
      json[r'expiresAt'] = null;
    }
    if (this.method != null) {
      json[r'method'] = this.method;
    } else {
      json[r'method'] = null;
    }
    if (this.bucket != null) {
      json[r'bucket'] = this.bucket;
    } else {
      json[r'bucket'] = null;
    }
    if (this.key != null) {
      json[r'key'] = this.key;
    } else {
      json[r'key'] = null;
    }
    return json;
  }

  /// Returns a new [SignedUrl] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static SignedUrl? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return SignedUrl(
        signedUrl: mapValueOfType<String>(json, r'signedUrl'),
        expiresAt: mapValueOfType<String>(json, r'expiresAt'),
        method: mapValueOfType<String>(json, r'method'),
        bucket: mapValueOfType<String>(json, r'bucket'),
        key: mapValueOfType<String>(json, r'key'),
      );
    }
    return null;
  }

  static List<SignedUrl> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <SignedUrl>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = SignedUrl.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, SignedUrl> mapFromJson(dynamic json) {
    final map = <String, SignedUrl>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = SignedUrl.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of SignedUrl-objects as value to a dart map
  static Map<String, List<SignedUrl>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<SignedUrl>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = SignedUrl.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}

