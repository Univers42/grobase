//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class TxnRequest {
  /// Returns a new [TxnRequest] instance.
  TxnRequest({
    required this.databaseId,
    this.operations = const [],
  });

  String databaseId;

  List<TxnRequestOperationsInner> operations;

  @override
  bool operator ==(Object other) => identical(this, other) || other is TxnRequest &&
    other.databaseId == databaseId &&
    _deepEquality.equals(other.operations, operations);

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (databaseId.hashCode) +
    (operations.hashCode);

  @override
  String toString() => 'TxnRequest[databaseId=$databaseId, operations=$operations]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'databaseId'] = this.databaseId;
      json[r'operations'] = this.operations;
    return json;
  }

  /// Returns a new [TxnRequest] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static TxnRequest? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        assert(json.containsKey(r'databaseId'), 'Required key "TxnRequest[databaseId]" is missing from JSON.');
        assert(json[r'databaseId'] != null, 'Required key "TxnRequest[databaseId]" has a null value in JSON.');
        assert(json.containsKey(r'operations'), 'Required key "TxnRequest[operations]" is missing from JSON.');
        assert(json[r'operations'] != null, 'Required key "TxnRequest[operations]" has a null value in JSON.');
        return true;
      }());

      return TxnRequest(
        databaseId: mapValueOfType<String>(json, r'databaseId')!,
        operations: TxnRequestOperationsInner.listFromJson(json[r'operations']),
      );
    }
    return null;
  }

  static List<TxnRequest> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <TxnRequest>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = TxnRequest.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, TxnRequest> mapFromJson(dynamic json) {
    final map = <String, TxnRequest>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = TxnRequest.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of TxnRequest-objects as value to a dart map
  static Map<String, List<TxnRequest>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<TxnRequest>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = TxnRequest.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
    'databaseId',
    'operations',
  };
}

