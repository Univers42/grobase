//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class MfaEnrollRequest {
  /// Returns a new [MfaEnrollRequest] instance.
  MfaEnrollRequest({
    this.factorType = const MfaEnrollRequestFactorTypeEnum._('totp'),
    this.friendlyName,
    this.issuer,
    this.phone,
  });

  MfaEnrollRequestFactorTypeEnum factorType;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? friendlyName;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? issuer;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? phone;

  @override
  bool operator ==(Object other) => identical(this, other) || other is MfaEnrollRequest &&
    other.factorType == factorType &&
    other.friendlyName == friendlyName &&
    other.issuer == issuer &&
    other.phone == phone;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (factorType.hashCode) +
    (friendlyName == null ? 0 : friendlyName!.hashCode) +
    (issuer == null ? 0 : issuer!.hashCode) +
    (phone == null ? 0 : phone!.hashCode);

  @override
  String toString() => 'MfaEnrollRequest[factorType=$factorType, friendlyName=$friendlyName, issuer=$issuer, phone=$phone]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'factor_type'] = this.factorType;
    if (this.friendlyName != null) {
      json[r'friendly_name'] = this.friendlyName;
    } else {
      json[r'friendly_name'] = null;
    }
    if (this.issuer != null) {
      json[r'issuer'] = this.issuer;
    } else {
      json[r'issuer'] = null;
    }
    if (this.phone != null) {
      json[r'phone'] = this.phone;
    } else {
      json[r'phone'] = null;
    }
    return json;
  }

  /// Returns a new [MfaEnrollRequest] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static MfaEnrollRequest? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return MfaEnrollRequest(
        factorType: MfaEnrollRequestFactorTypeEnum.fromJson(json[r'factor_type']) ?? const MfaEnrollRequestFactorTypeEnum._('totp'),
        friendlyName: mapValueOfType<String>(json, r'friendly_name'),
        issuer: mapValueOfType<String>(json, r'issuer'),
        phone: mapValueOfType<String>(json, r'phone'),
      );
    }
    return null;
  }

  static List<MfaEnrollRequest> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <MfaEnrollRequest>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = MfaEnrollRequest.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, MfaEnrollRequest> mapFromJson(dynamic json) {
    final map = <String, MfaEnrollRequest>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = MfaEnrollRequest.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of MfaEnrollRequest-objects as value to a dart map
  static Map<String, List<MfaEnrollRequest>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<MfaEnrollRequest>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = MfaEnrollRequest.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}


class MfaEnrollRequestFactorTypeEnum {
  /// Instantiate a new enum with the provided [value].
  const MfaEnrollRequestFactorTypeEnum._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const totp = MfaEnrollRequestFactorTypeEnum._(r'totp');
  static const phone = MfaEnrollRequestFactorTypeEnum._(r'phone');

  /// List of all possible values in this [enum][MfaEnrollRequestFactorTypeEnum].
  static const values = <MfaEnrollRequestFactorTypeEnum>[
    totp,
    phone,
  ];

  static MfaEnrollRequestFactorTypeEnum? fromJson(dynamic value) => MfaEnrollRequestFactorTypeEnumTypeTransformer().decode(value);

  static List<MfaEnrollRequestFactorTypeEnum> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <MfaEnrollRequestFactorTypeEnum>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = MfaEnrollRequestFactorTypeEnum.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [MfaEnrollRequestFactorTypeEnum] to String,
/// and [decode] dynamic data back to [MfaEnrollRequestFactorTypeEnum].
class MfaEnrollRequestFactorTypeEnumTypeTransformer {
  factory MfaEnrollRequestFactorTypeEnumTypeTransformer() => _instance ??= const MfaEnrollRequestFactorTypeEnumTypeTransformer._();

  const MfaEnrollRequestFactorTypeEnumTypeTransformer._();

  String encode(MfaEnrollRequestFactorTypeEnum data) => data.value;

  /// Decodes a [dynamic value][data] to a MfaEnrollRequestFactorTypeEnum.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  MfaEnrollRequestFactorTypeEnum? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'totp': return MfaEnrollRequestFactorTypeEnum.totp;
        case r'phone': return MfaEnrollRequestFactorTypeEnum.phone;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [MfaEnrollRequestFactorTypeEnumTypeTransformer] instance.
  static MfaEnrollRequestFactorTypeEnumTypeTransformer? _instance;
}


