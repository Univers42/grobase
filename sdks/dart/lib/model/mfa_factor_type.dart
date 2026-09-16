//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

part of openapi.api;

/// Second-factor type. Named rather than inline so generated clients emit a real enum type.
class MfaFactorType {
  /// Instantiate a new enum with the provided [value].
  const MfaFactorType._(this.value);

  /// The underlying value of this enum member.
  final String value;

  @override
  String toString() => value;

  String toJson() => value;

  static const totp = MfaFactorType._(r'totp');
  static const phone = MfaFactorType._(r'phone');

  /// List of all possible values in this [enum][MfaFactorType].
  static const values = <MfaFactorType>[
    totp,
    phone,
  ];

  static MfaFactorType? fromJson(dynamic value) => MfaFactorTypeTypeTransformer().decode(value);

  static List<MfaFactorType> listFromJson(dynamic json, {bool growable = false,}) {
    final result = <MfaFactorType>[];
    if (json is List && json.isNotEmpty) {
      for (final row in json) {
        final value = MfaFactorType.fromJson(row);
        if (value != null) {
          result.add(value);
        }
      }
    }
    return result.toList(growable: growable);
  }
}

/// Transformation class that can [encode] an instance of [MfaFactorType] to String,
/// and [decode] dynamic data back to [MfaFactorType].
class MfaFactorTypeTypeTransformer {
  factory MfaFactorTypeTypeTransformer() => _instance ??= const MfaFactorTypeTypeTransformer._();

  const MfaFactorTypeTypeTransformer._();

  String encode(MfaFactorType data) => data.value;

  /// Decodes a [dynamic value][data] to a MfaFactorType.
  ///
  /// If [allowNull] is true and the [dynamic value][data] cannot be decoded successfully,
  /// then null is returned. However, if [allowNull] is false and the [dynamic value][data]
  /// cannot be decoded successfully, then an [UnimplementedError] is thrown.
  ///
  /// The [allowNull] is very handy when an API changes and a new enum value is added or removed,
  /// and users are still using an old app with the old code.
  MfaFactorType? decode(dynamic data, {bool allowNull = true}) {
    if (data != null) {
      switch (data) {
        case r'totp': return MfaFactorType.totp;
        case r'phone': return MfaFactorType.phone;
        default:
          if (!allowNull) {
            throw ArgumentError('Unknown enum value to decode: $data');
          }
      }
    }
    return null;
  }

  /// Singleton [MfaFactorTypeTypeTransformer] instance.
  static MfaFactorTypeTypeTransformer? _instance;
}

