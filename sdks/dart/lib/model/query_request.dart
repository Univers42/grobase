//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class QueryRequest {
  /// Returns a new [QueryRequest] instance.
  QueryRequest({
    required this.databaseId,
    required this.action,
    required this.resource,
    this.payload = const {},
  });

  String databaseId;

  String action;

  String resource;

  Map<String, Object> payload;

  @override
  bool operator ==(Object other) => identical(this, other) || other is QueryRequest &&
    other.databaseId == databaseId &&
    other.action == action &&
    other.resource == resource &&
    _deepEquality.equals(other.payload, payload);

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (databaseId.hashCode) +
    (action.hashCode) +
    (resource.hashCode) +
    (payload.hashCode);

  @override
  String toString() => 'QueryRequest[databaseId=$databaseId, action=$action, resource=$resource, payload=$payload]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'database_id'] = this.databaseId;
      json[r'action'] = this.action;
      json[r'resource'] = this.resource;
      json[r'payload'] = this.payload;
    return json;
  }

  /// Returns a new [QueryRequest] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static QueryRequest? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        assert(json.containsKey(r'database_id'), 'Required key "QueryRequest[database_id]" is missing from JSON.');
        assert(json[r'database_id'] != null, 'Required key "QueryRequest[database_id]" has a null value in JSON.');
        assert(json.containsKey(r'action'), 'Required key "QueryRequest[action]" is missing from JSON.');
        assert(json[r'action'] != null, 'Required key "QueryRequest[action]" has a null value in JSON.');
        assert(json.containsKey(r'resource'), 'Required key "QueryRequest[resource]" is missing from JSON.');
        assert(json[r'resource'] != null, 'Required key "QueryRequest[resource]" has a null value in JSON.');
        return true;
      }());

      return QueryRequest(
        databaseId: mapValueOfType<String>(json, r'database_id')!,
        action: mapValueOfType<String>(json, r'action')!,
        resource: mapValueOfType<String>(json, r'resource')!,
        payload: mapCastOfType<String, Object>(json, r'payload') ?? const {},
      );
    }
    return null;
  }

  static List<QueryRequest> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <QueryRequest>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = QueryRequest.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, QueryRequest> mapFromJson(dynamic json) {
    final map = <String, QueryRequest>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = QueryRequest.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of QueryRequest-objects as value to a dart map
  static Map<String, List<QueryRequest>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<QueryRequest>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = QueryRequest.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
    'database_id',
    'action',
    'resource',
  };
}

