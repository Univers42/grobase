//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

class StorageListBuckets200Response {
  /// Returns a new [StorageListBuckets200Response] instance.
  StorageListBuckets200Response({
    this.buckets = const [],
  });

  List<BucketInfo> buckets;

  @override
  bool operator ==(Object other) => identical(this, other) || other is StorageListBuckets200Response &&
    _deepEquality.equals(other.buckets, buckets);

  @override
  int get hashCode =>
    // ignore: unnecessary_parenthesis
    (buckets.hashCode);

  @override
  String toString() => 'StorageListBuckets200Response[buckets=$buckets]';

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
      json[r'buckets'] = this.buckets;
    return json;
  }

  /// Returns a new [StorageListBuckets200Response] instance and imports its values from
  /// [value] if it's a [Map], null otherwise.
  // ignore: prefer_constructors_over_static_methods
  static StorageListBuckets200Response? fromJson(dynamic value) {
    if (value is Map) {
      final json = value.cast<String, dynamic>();

      // Ensure that the map contains the required keys.
      // Note 1: the values aren't checked for validity beyond being non-null.
      // Note 2: this code is stripped in release mode!
      assert(() {
        return true;
      }());

      return StorageListBuckets200Response(
        buckets: BucketInfo.listFromJson(json[r'buckets']),
      );
    }
    return null;
  }

  static List<StorageListBuckets200Response> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <StorageListBuckets200Response>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = StorageListBuckets200Response.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }

  static Map<String, StorageListBuckets200Response> mapFromJson(dynamic json) {
    final map = <String, StorageListBuckets200Response>{};
    if (json is Map && json.isNotEmpty) {
      json = json.cast<String, dynamic>(); // ignore: parameter_assignments
      for (final entry in json.entries) {
        final value = StorageListBuckets200Response.fromJson(entry.value);
        if (value != null) {
          map[entry.key] = value;
        }
      }
    }
    return map;
  }

  // maps a json object with a list of StorageListBuckets200Response-objects as value to a dart map
  static Map<String, List<StorageListBuckets200Response>> mapListFromJson(dynamic json, {bool growable = false,}) {
    final map = <String, List<StorageListBuckets200Response>>{};
    if (json is Map && json.isNotEmpty) {
      // ignore: parameter_assignments
      json = json.cast<String, dynamic>();
      for (final entry in json.entries) {
        map[entry.key] = StorageListBuckets200Response.listFromJson(entry.value, growable: growable,);
      }
    }
    return map;
  }

  /// The list of required keys that must be present in a JSON.
  static const requiredKeys = <String>{
  };
}

