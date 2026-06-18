//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class StorageCreateBucket200Response {
  /// Returns a new [StorageCreateBucket200Response] instance.
  StorageCreateBucket200Response({
    this.name,
    this.created,
  });

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  String? name;

  ///
  /// Please note: This property should have been non-nullable! Since the specification file
  /// does not include a default value (using the "default:" property), however, the generated
  /// source code must fall back to having a nullable type.
  /// Consider adding a "default:" property in the specification file to hide this note.
  ///
  bool? created;

  @override
  bool operator ==(Object other) => identical(this, other) || other is StorageCreateBucket200Response &&
    other.name == name &&
    other.created == created;

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (name == null ? 0 : name!.hashCode) +
    (created == null ? 0 : created!.hashCode);

  @override
  String toString() => 'StorageCreateBucket200Response[name=$name, created=$created]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (this.name != null) {
      json[r'name'] = this.name;
    } else {
      json[r'name'] = null;
    }
    if (this.created != null) {
      json[r'created'] = this.created;
    } else {
      json[r'created'] = null;
    }
    return json;
  }

  /// Returns a new [StorageCreateBucket200Response] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static StorageCreateBucket200Response? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return StorageCreateBucket200Response(
        name: mapValueOfType<String>(json, r'name'),
        created: mapValueOfType<bool>(json, r'created'),
      );
    }
    return null;
  }

  static List<StorageCreateBucket200Response> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <StorageCreateBucket200Response>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = StorageCreateBucket200Response.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, StorageCreateBucket200Response> mapFromJson(dynamic json) {
    final map = <String, StorageCreateBucket200Response>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = StorageCreateBucket200Response.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of StorageCreateBucket200Response-objects as value to a dart map
  static Map<String, List<StorageCreateBucket200Response>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<StorageCreateBucket200Response>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = StorageCreateBucket200Response.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}

