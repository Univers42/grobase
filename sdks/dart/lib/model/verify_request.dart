//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class VerifyRequest {
  /// Returns a new [VerifyRequest] instance.
  VerifyRequest({
    required this.type,
    this.token,
    this.tokenHash,
  });

  VerifyRequestTypeEnum type;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? token;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? tokenHash;

  @override
  bool operator ==(Object other) => identical(this, other) || other is VerifyRequest &&
    other.type == type &&
    other.token == token &&
    other.tokenHash == tokenHash;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (type.hashCode) +
    (token == null ? 0 : token!.hashCode) +
    (tokenHash == null ? 0 : tokenHash!.hashCode);

  @override
  String toString() => 'VerifyRequest[type=$type, token=$token, tokenHash=$tokenHash]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'type'] = this.type;
    if (this.token != null) {
      json[r'token'] = this.token;
    } else {
      json[r'token'] = null;
    }
    if (this.tokenHash != null) {
      json[r'token_hash'] = this.tokenHash;
    } else {
      json[r'token_hash'] = null;
    }
    return json;
  }

  /// Returns a new [VerifyRequest] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static VerifyRequest? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        assert(json.containsKey(r'type'), 'Required key "VerifyRequest[type]" is missing from JSON.');
        assert(json[r'type'] != null, 'Required key "VerifyRequest[type]" has a null value in JSON.');
        return true;
      }());

      return VerifyRequest(
        type: VerifyRequestTypeEnum.fromJson(json[r'type'])!,
        token: mapValueOfType<String>(json, r'token'),
        tokenHash: mapValueOfType<String>(json, r'token_hash'),
      );
    }
    return null;
  }

  static List<VerifyRequest> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <VerifyRequest>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = VerifyRequest.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, VerifyRequest> mapFromJson(dynamic json) {
    final map = <String, VerifyRequest>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = VerifyRequest.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of VerifyRequest-objects as value to a dart map
  static Map<String, List<VerifyRequest>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<VerifyRequest>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = VerifyRequest.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
    'type',
  };
}


class VerifyRequestTypeEnum {
  /// Instantiate a new enum with the provided [value].
  const VerifyRequestTypeEnum._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const signup = VerifyRequestTypeEnum._(r'signup');
  static const recovery = VerifyRequestTypeEnum._(r'recovery');
  static const magiclink = VerifyRequestTypeEnum._(r'magiclink');
  static const emailChange = VerifyRequestTypeEnum._(r'email_change');

  /// List of all possible values in this [enum][VerifyRequestTypeEnum].
  static const values = <VerifyRequestTypeEnum>[
    signup,
    recovery,
    magiclink,
    emailChange,
  ];

  static VerifyRequestTypeEnum? fromJson(dynamic value) => VerifyRequestTypeEnumTypeTransformer().decode(value);

  static List<VerifyRequestTypeEnum> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <VerifyRequestTypeEnum>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = VerifyRequestTypeEnum.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [VerifyRequestTypeEnum] to String,
/// and [decode] dynamic data back to [VerifyRequestTypeEnum].
class VerifyRequestTypeEnumTypeTransformer {
  factory VerifyRequestTypeEnumTypeTransformer() => _instance ??= const VerifyRequestTypeEnumTypeTransformer._();

  const VerifyRequestTypeEnumTypeTransformer._();

  String encode(VerifyRequestTypeEnum data) => data.value;

  /// Decodes a [dynamic value][data] to a VerifyRequestTypeEnum.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  VerifyRequestTypeEnum? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'signup': return VerifyRequestTypeEnum.signup;
        case r'recovery': return VerifyRequestTypeEnum.recovery;
        case r'magiclink': return VerifyRequestTypeEnum.magiclink;
        case r'email_change': return VerifyRequestTypeEnum.emailChange;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [VerifyRequestTypeEnumTypeTransformer] instance.
  static VerifyRequestTypeEnumTypeTransformer? _instance;
}


