//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class MfaEnrollResponseTotp {
  /// Returns a new [MfaEnrollResponseTotp] instance.
  MfaEnrollResponseTotp({
    this.qrCode,
    this.secret,
    this.uri,
  });

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? qrCode;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? secret;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? uri;

  @override
  bool operator ==(Object other) => identical(this, other) || other is MfaEnrollResponseTotp &&
    other.qrCode == qrCode &&
    other.secret == secret &&
    other.uri == uri;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (qrCode == null ? 0 : qrCode!.hashCode) +
    (secret == null ? 0 : secret!.hashCode) +
    (uri == null ? 0 : uri!.hashCode);

  @override
  String toString() => 'MfaEnrollResponseTotp[qrCode=$qrCode, secret=$secret, uri=$uri]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (this.qrCode != null) {
      json[r'qr_code'] = this.qrCode;
    } else {
      json[r'qr_code'] = null;
    }
    if (this.secret != null) {
      json[r'secret'] = this.secret;
    } else {
      json[r'secret'] = null;
    }
    if (this.uri != null) {
      json[r'uri'] = this.uri;
    } else {
      json[r'uri'] = null;
    }
    return json;
  }

  /// Returns a new [MfaEnrollResponseTotp] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static MfaEnrollResponseTotp? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return MfaEnrollResponseTotp(
        qrCode: mapValueOfType<String>(json, r'qr_code'),
        secret: mapValueOfType<String>(json, r'secret'),
        uri: mapValueOfType<String>(json, r'uri'),
      );
    }
    return null;
  }

  static List<MfaEnrollResponseTotp> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <MfaEnrollResponseTotp>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = MfaEnrollResponseTotp.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, MfaEnrollResponseTotp> mapFromJson(dynamic json) {
    final map = <String, MfaEnrollResponseTotp>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = MfaEnrollResponseTotp.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of MfaEnrollResponseTotp-objects as value to a dart map
  static Map<String, List<MfaEnrollResponseTotp>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<MfaEnrollResponseTotp>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = MfaEnrollResponseTotp.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}

