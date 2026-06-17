//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class MfaEnrollResponse {
  /// Returns a new [MfaEnrollResponse] instance.
  MfaEnrollResponse({
    required this.id,
    required this.type,
    this.friendlyName,
    this.totp,
  });

  String id;

  MfaEnrollResponseTypeEnum type;

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
  MfaEnrollResponseTotp? totp;

  @override
  bool operator ==(Object other) => identical(this, other) || other is MfaEnrollResponse &&
    other.id == id &&
    other.type == type &&
    other.friendlyName == friendlyName &&
    other.totp == totp;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (id.hashCode) +
    (type.hashCode) +
    (friendlyName == null ? 0 : friendlyName!.hashCode) +
    (totp == null ? 0 : totp!.hashCode);

  @override
  String toString() => 'MfaEnrollResponse[id=$id, type=$type, friendlyName=$friendlyName, totp=$totp]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'id'] = this.id;
      json[r'type'] = this.type;
    if (this.friendlyName != null) {
      json[r'friendly_name'] = this.friendlyName;
    } else {
      json[r'friendly_name'] = null;
    }
    if (this.totp != null) {
      json[r'totp'] = this.totp;
    } else {
      json[r'totp'] = null;
    }
    return json;
  }

  /// Returns a new [MfaEnrollResponse] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static MfaEnrollResponse? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        assert(json.containsKey(r'id'), 'Required key "MfaEnrollResponse[id]" is missing from JSON.');
        assert(json[r'id'] != null, 'Required key "MfaEnrollResponse[id]" has a null value in JSON.');
        assert(json.containsKey(r'type'), 'Required key "MfaEnrollResponse[type]" is missing from JSON.');
        assert(json[r'type'] != null, 'Required key "MfaEnrollResponse[type]" has a null value in JSON.');
        return true;
      }());

      return MfaEnrollResponse(
        id: mapValueOfType<String>(json, r'id')!,
        type: MfaEnrollResponseTypeEnum.fromJson(json[r'type'])!,
        friendlyName: mapValueOfType<String>(json, r'friendly_name'),
        totp: MfaEnrollResponseTotp.fromJson(json[r'totp']),
      );
    }
    return null;
  }

  static List<MfaEnrollResponse> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <MfaEnrollResponse>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = MfaEnrollResponse.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, MfaEnrollResponse> mapFromJson(dynamic json) {
    final map = <String, MfaEnrollResponse>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = MfaEnrollResponse.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of MfaEnrollResponse-objects as value to a dart map
  static Map<String, List<MfaEnrollResponse>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<MfaEnrollResponse>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = MfaEnrollResponse.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
    'id',
    'type',
  };
}


class MfaEnrollResponseTypeEnum {
  /// Instantiate a new enum with the provided [value].
  const MfaEnrollResponseTypeEnum._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const totp = MfaEnrollResponseTypeEnum._(r'totp');
  static const phone = MfaEnrollResponseTypeEnum._(r'phone');

  /// List of all possible values in this [enum][MfaEnrollResponseTypeEnum].
  static const values = <MfaEnrollResponseTypeEnum>[
    totp,
    phone,
  ];

  static MfaEnrollResponseTypeEnum? fromJson(dynamic value) => MfaEnrollResponseTypeEnumTypeTransformer().decode(value);

  static List<MfaEnrollResponseTypeEnum> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <MfaEnrollResponseTypeEnum>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = MfaEnrollResponseTypeEnum.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [MfaEnrollResponseTypeEnum] to String,
/// and [decode] dynamic data back to [MfaEnrollResponseTypeEnum].
class MfaEnrollResponseTypeEnumTypeTransformer {
  factory MfaEnrollResponseTypeEnumTypeTransformer() => _instance ??= const MfaEnrollResponseTypeEnumTypeTransformer._();

  const MfaEnrollResponseTypeEnumTypeTransformer._();

  String encode(MfaEnrollResponseTypeEnum data) => data.value;

  /// Decodes a [dynamic value][data] to a MfaEnrollResponseTypeEnum.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  MfaEnrollResponseTypeEnum? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'totp': return MfaEnrollResponseTypeEnum.totp;
        case r'phone': return MfaEnrollResponseTypeEnum.phone;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [MfaEnrollResponseTypeEnumTypeTransformer] instance.
  static MfaEnrollResponseTypeEnumTypeTransformer? _instance;
}


