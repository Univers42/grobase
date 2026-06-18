//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class TxnRequestOperationsInner {
  /// Returns a new [TxnRequestOperationsInner] instance.
  TxnRequestOperationsInner({
    required this.op,
    required this.resource,
    this.data = const {},
    this.filter = const {},
    this.idempotencyKey,
  });

  TxnRequestOperationsInnerOpEnum op;

  String resource;

  Map<String, Object> data;

  Map<String, Object> filter;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? idempotencyKey;

  @override
  bool operator ==(Object other) => identical(this, other) || other is TxnRequestOperationsInner &&
    other.op == op &&
    other.resource == resource &&
    _deepEquality.equals(other.data, data) &&
    _deepEquality.equals(other.filter, filter) &&
    other.idempotencyKey == idempotencyKey;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (op.hashCode) +
    (resource.hashCode) +
    (data.hashCode) +
    (filter.hashCode) +
    (idempotencyKey == null ? 0 : idempotencyKey!.hashCode);

  @override
  String toString() => 'TxnRequestOperationsInner[op=$op, resource=$resource, data=$data, filter=$filter, idempotencyKey=$idempotencyKey]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'op'] = this.op;
      json[r'resource'] = this.resource;
      json[r'data'] = this.data;
      json[r'filter'] = this.filter;
    if (this.idempotencyKey != null) {
      json[r'idempotencyKey'] = this.idempotencyKey;
    } else {
      json[r'idempotencyKey'] = null;
    }
    return json;
  }

  /// Returns a new [TxnRequestOperationsInner] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static TxnRequestOperationsInner? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        assert(json.containsKey(r'op'), 'Required key "TxnRequestOperationsInner[op]" is missing from JSON.');
        assert(json[r'op'] != null, 'Required key "TxnRequestOperationsInner[op]" has a null value in JSON.');
        assert(json.containsKey(r'resource'), 'Required key "TxnRequestOperationsInner[resource]" is missing from JSON.');
        assert(json[r'resource'] != null, 'Required key "TxnRequestOperationsInner[resource]" has a null value in JSON.');
        return true;
      }());

      return TxnRequestOperationsInner(
        op: TxnRequestOperationsInnerOpEnum.fromJson(json[r'op'])!,
        resource: mapValueOfType<String>(json, r'resource')!,
        data: mapCastOfType<String, Object>(json, r'data') ?? const {},
        filter: mapCastOfType<String, Object>(json, r'filter') ?? const {},
        idempotencyKey: mapValueOfType<String>(json, r'idempotencyKey'),
      );
    }
    return null;
  }

  static List<TxnRequestOperationsInner> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <TxnRequestOperationsInner>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = TxnRequestOperationsInner.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, TxnRequestOperationsInner> mapFromJson(dynamic json) {
    final map = <String, TxnRequestOperationsInner>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = TxnRequestOperationsInner.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of TxnRequestOperationsInner-objects as value to a dart map
  static Map<String, List<TxnRequestOperationsInner>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<TxnRequestOperationsInner>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = TxnRequestOperationsInner.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
    'op',
    'resource',
  };
}


class TxnRequestOperationsInnerOpEnum {
  /// Instantiate a new enum with the provided [value].
  const TxnRequestOperationsInnerOpEnum._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const insert = TxnRequestOperationsInnerOpEnum._(r'insert');
  static const update = TxnRequestOperationsInnerOpEnum._(r'update');
  static const delete = TxnRequestOperationsInnerOpEnum._(r'delete');
  static const upsert = TxnRequestOperationsInnerOpEnum._(r'upsert');

  /// List of all possible values in this [enum][TxnRequestOperationsInnerOpEnum].
  static const values = <TxnRequestOperationsInnerOpEnum>[
    insert,
    update,
    delete,
    upsert,
  ];

  static TxnRequestOperationsInnerOpEnum? fromJson(dynamic value) => TxnRequestOperationsInnerOpEnumTypeTransformer().decode(value);

  static List<TxnRequestOperationsInnerOpEnum> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <TxnRequestOperationsInnerOpEnum>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = TxnRequestOperationsInnerOpEnum.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [TxnRequestOperationsInnerOpEnum] to String,
/// and [decode] dynamic data back to [TxnRequestOperationsInnerOpEnum].
class TxnRequestOperationsInnerOpEnumTypeTransformer {
  factory TxnRequestOperationsInnerOpEnumTypeTransformer() => _instance ??= const TxnRequestOperationsInnerOpEnumTypeTransformer._();

  const TxnRequestOperationsInnerOpEnumTypeTransformer._();

  String encode(TxnRequestOperationsInnerOpEnum data) => data.value;

  /// Decodes a [dynamic value][data] to a TxnRequestOperationsInnerOpEnum.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  TxnRequestOperationsInnerOpEnum? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'insert': return TxnRequestOperationsInnerOpEnum.insert;
        case r'update': return TxnRequestOperationsInnerOpEnum.update;
        case r'delete': return TxnRequestOperationsInnerOpEnum.delete;
        case r'upsert': return TxnRequestOperationsInnerOpEnum.upsert;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [TxnRequestOperationsInnerOpEnumTypeTransformer] instance.
  static TxnRequestOperationsInnerOpEnumTypeTransformer? _instance;
}


