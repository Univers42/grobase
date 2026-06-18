//
// AUTO-GENERATED FILE, DO NOT MODIFY!
//
// @dart=2.18

// ignore_for_file: unused_element, unused_import
// ignore_for_file: always_put_required_named_parameters_first
// ignore_for_file: constant_identifier_names
// ignore_for_file: lines_longer_than_80_chars

library openapi.api;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:http/http.dart';
import 'package:intl/intl.dart';
import 'package:meta/meta.dart';

part 'api_client.dart';
part 'api_helper.dart';
part 'api_exception.dart';
part 'auth/authentication.dart';
part 'auth/api_key_auth.dart';
part 'auth/oauth.dart';
part 'auth/http_basic_auth.dart';
part 'auth/http_bearer_auth.dart';

part 'api/auth_api.dart';
part 'api/functions_api.dart';
part 'api/query_api.dart';
part 'api/rest_api.dart';
part 'api/storage_api.dart';

part 'model/auth_recover_request.dart';
part 'model/auth_sign_up200_response.dart';
part 'model/bucket_info.dart';
part 'model/error.dart';
part 'model/function_get200_response.dart';
part 'model/mfa_challenge_response.dart';
part 'model/mfa_enroll_request.dart';
part 'model/mfa_enroll_response.dart';
part 'model/mfa_enroll_response_totp.dart';
part 'model/mfa_verify_request.dart';
part 'model/query_engines200_response.dart';
part 'model/query_request.dart';
part 'model/query_response.dart';
part 'model/session.dart';
part 'model/sign_up_request.dart';
part 'model/signed_url.dart';
part 'model/storage_create_bucket200_response.dart';
part 'model/storage_list200_response.dart';
part 'model/storage_list_buckets200_response.dart';
part 'model/storage_object.dart';
part 'model/storage_sign_request.dart';
part 'model/token_request.dart';
part 'model/txn_request.dart';
part 'model/txn_request_operations_inner.dart';
part 'model/txn_response.dart';
part 'model/txn_response_results_inner.dart';
part 'model/update_user_request.dart';
part 'model/upload_result.dart';
part 'model/user.dart';
part 'model/verify_request.dart';


/// An [ApiClient] instance that uses the default values obtained from
/// the OpenAPI specification file.
var defaultApiClient = ApiClient();

const _delimiters = {'csv': ',', 'ssv': ' ', 'tsv': '\t', 'pipes': '|'};
const _dateEpochMarker = 'epoch';
const _deepEquality = DeepCollectionEquality();
final _dateFormatter = DateFormat('yyyy-MM-dd');
final _regList = RegExp(r'^List<(.*)>$');
final _regSet = RegExp(r'^Set<(.*)>$');
final _regMap = RegExp(r'^Map<String,(.*)>$');

bool _isEpochMarker(String? pattern) => pattern == _dateEpochMarker || pattern == '/$_dateEpochMarker/';
