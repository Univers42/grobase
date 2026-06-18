//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class StorageSignRequest {
  /// Returns a new [StorageSignRequest] instance.
  StorageSignRequest({
    this.method,
    this.expiresIn,
    this.contentType,
  });

  StorageSignRequestMethodEnum? method;

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
  String? contentType;

  @override
  bool operator ==(Object other) => identical(this, other) || other is StorageSignRequest &&
    other.method == method &&
    other.expiresIn == expiresIn &&
    other.contentType == contentType;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (method == null ? 0 : method!.hashCode) +
    (expiresIn == null ? 0 : expiresIn!.hashCode) +
    (contentType == null ? 0 : contentType!.hashCode);

  @override
  String toString() => 'StorageSignRequest[method=$method, expiresIn=$expiresIn, contentType=$contentType]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (this.method != null) {
      json[r'method'] = this.method;
    } else {
      json[r'method'] = null;
    }
    if (this.expiresIn != null) {
      json[r'expiresIn'] = this.expiresIn;
    } else {
      json[r'expiresIn'] = null;
    }
    if (this.contentType != null) {
      json[r'contentType'] = this.contentType;
    } else {
      json[r'contentType'] = null;
    }
    return json;
  }

  /// Returns a new [StorageSignRequest] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static StorageSignRequest? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return StorageSignRequest(
        method: StorageSignRequestMethodEnum.fromJson(json[r'method']),
        expiresIn: mapValueOfType<int>(json, r'expiresIn'),
        contentType: mapValueOfType<String>(json, r'contentType'),
      );
    }
    return null;
  }

  static List<StorageSignRequest> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <StorageSignRequest>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = StorageSignRequest.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, StorageSignRequest> mapFromJson(dynamic json) {
    final map = <String, StorageSignRequest>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = StorageSignRequest.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of StorageSignRequest-objects as value to a dart map
  static Map<String, List<StorageSignRequest>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<StorageSignRequest>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = StorageSignRequest.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}


class StorageSignRequestMethodEnum {
  /// Instantiate a new enum with the provided [value].
  const StorageSignRequestMethodEnum._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const GET = StorageSignRequestMethodEnum._(r'GET');
  static const PUT = StorageSignRequestMethodEnum._(r'PUT');

  /// List of all possible values in this [enum][StorageSignRequestMethodEnum].
  static const values = <StorageSignRequestMethodEnum>[
    GET,
    PUT,
  ];

  static StorageSignRequestMethodEnum? fromJson(dynamic value) => StorageSignRequestMethodEnumTypeTransformer().decode(value);

  static List<StorageSignRequestMethodEnum> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <StorageSignRequestMethodEnum>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = StorageSignRequestMethodEnum.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [StorageSignRequestMethodEnum] to String,
/// and [decode] dynamic data back to [StorageSignRequestMethodEnum].
class StorageSignRequestMethodEnumTypeTransformer {
  factory StorageSignRequestMethodEnumTypeTransformer() => _instance ??= const StorageSignRequestMethodEnumTypeTransformer._();

  const StorageSignRequestMethodEnumTypeTransformer._();

  String encode(StorageSignRequestMethodEnum data) => data.value;

  /// Decodes a [dynamic value][data] to a StorageSignRequestMethodEnum.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  StorageSignRequestMethodEnum? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'GET': return StorageSignRequestMethodEnum.GET;
        case r'PUT': return StorageSignRequestMethodEnum.PUT;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [StorageSignRequestMethodEnumTypeTransformer] instance.
  static StorageSignRequestMethodEnumTypeTransformer? _instance;
}


