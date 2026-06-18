//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class TxnResponse {
  /// Returns a new [TxnResponse] instance.
  TxnResponse({
    this.guarantee,
    this.mount,
    this.results = const [],
  });

  TxnResponseGuaranteeEnum? guarantee;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? mount;

  List<TxnResponseResultsInner> results;

  @override
  bool operator ==(Object other) => identical(this, other) || other is TxnResponse &&
    other.guarantee == guarantee &&
    other.mount == mount &&
    _deepEquality.equals(other.results, results);

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (guarantee == null ? 0 : guarantee!.hashCode) +
    (mount == null ? 0 : mount!.hashCode) +
    (results.hashCode);

  @override
  String toString() => 'TxnResponse[guarantee=$guarantee, mount=$mount, results=$results]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (this.guarantee != null) {
      json[r'guarantee'] = this.guarantee;
    } else {
      json[r'guarantee'] = null;
    }
    if (this.mount != null) {
      json[r'mount'] = this.mount;
    } else {
      json[r'mount'] = null;
    }
      json[r'results'] = this.results;
    return json;
  }

  /// Returns a new [TxnResponse] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static TxnResponse? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return TxnResponse(
        guarantee: TxnResponseGuaranteeEnum.fromJson(json[r'guarantee']),
        mount: mapValueOfType<String>(json, r'mount'),
        results: TxnResponseResultsInner.listFromJson(json[r'results']),
      );
    }
    return null;
  }

  static List<TxnResponse> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <TxnResponse>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = TxnResponse.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, TxnResponse> mapFromJson(dynamic json) {
    final map = <String, TxnResponse>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = TxnResponse.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of TxnResponse-objects as value to a dart map
  static Map<String, List<TxnResponse>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<TxnResponse>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = TxnResponse.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}


class TxnResponseGuaranteeEnum {
  /// Instantiate a new enum with the provided [value].
  const TxnResponseGuaranteeEnum._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const atomic = TxnResponseGuaranteeEnum._(r'atomic');

  /// List of all possible values in this [enum][TxnResponseGuaranteeEnum].
  static const values = <TxnResponseGuaranteeEnum>[
    atomic,
  ];

  static TxnResponseGuaranteeEnum? fromJson(dynamic value) => TxnResponseGuaranteeEnumTypeTransformer().decode(value);

  static List<TxnResponseGuaranteeEnum> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <TxnResponseGuaranteeEnum>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = TxnResponseGuaranteeEnum.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [TxnResponseGuaranteeEnum] to String,
/// and [decode] dynamic data back to [TxnResponseGuaranteeEnum].
class TxnResponseGuaranteeEnumTypeTransformer {
  factory TxnResponseGuaranteeEnumTypeTransformer() => _instance ??= const TxnResponseGuaranteeEnumTypeTransformer._();

  const TxnResponseGuaranteeEnumTypeTransformer._();

  String encode(TxnResponseGuaranteeEnum data) => data.value;

  /// Decodes a [dynamic value][data] to a TxnResponseGuaranteeEnum.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  TxnResponseGuaranteeEnum? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'atomic': return TxnResponseGuaranteeEnum.atomic;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [TxnResponseGuaranteeEnumTypeTransformer] instance.
  static TxnResponseGuaranteeEnumTypeTransformer? _instance;
}


