import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camagru_mobile/services/auth_service.dart';
import 'package:camagru_mobile/services/grobase_client.dart';
import 'package:camagru_mobile/services/token_store.dart';
import 'support/recording_adapter.dart';

/// In-memory [TokenStore] double so persistence is asserted without a platform
/// secure-storage channel.
class FakeTokenStore implements TokenStore {
  StoredSession? saved;
  bool cleared = false;

  @override
  Future<void> save(StoredSession session) async => saved = session;

  @override
  Future<StoredSession?> load() async => saved;

  @override
  Future<void> clear() async {
    saved = null;
    cleared = true;
  }
}

Map<String, dynamic> _session(String id) => {
      'access_token': 'access-$id',
      'refresh_token': 'refresh-$id',
      'user': {'id': id, 'email': '$id@canagrou.local'},
    };

void main() {
  late RecordingAdapter adapter;
  late FakeTokenStore store;
  late AuthService auth;

  setUp(() {
    adapter = RecordingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
      ..httpClientAdapter = adapter;
    final client = GrobaseClient(config: testConfig(), dio: dio);
    store = FakeTokenStore();
    auth = AuthService(client, store);
  });

  test('signUp posts email/password/username and persists tokens', () async {
    adapter.onPath('/auth/v1/signup', data: _session('sub-1'));
    final result = await auth.signUp(
      email: 'a@b.com',
      password: 'Secret!9',
      username: 'alice',
    );

    final req = adapter.firstWithPath('/auth/v1/signup');
    expect(req.headers['apikey'], 'anon-key');
    expect(req.jsonBody['email'], 'a@b.com');
    expect(req.jsonBody['password'], 'Secret!9');
    expect(req.jsonBody['data'], {'username': 'alice'});

    expect(result.userId, 'sub-1');
    expect(store.saved?.accessToken, 'access-sub-1');
    expect(store.saved?.refreshToken, 'refresh-sub-1');
    expect(store.saved?.userId, 'sub-1');
  });

  test('signInWithPassword uses grant_type=password and persists', () async {
    adapter.onPath('/auth/v1/token', data: _session('sub-2'));
    await auth.signInWithPassword(email: 'a@b.com', password: 'pw');

    final req = adapter.firstWithPath('/auth/v1/token');
    expect(req.queryParameters?['grant_type'], 'password');
    expect(req.jsonBody['email'], 'a@b.com');
    expect(req.jsonBody['password'], 'pw');
    expect(store.saved?.userId, 'sub-2');
  });

  test('refresh uses the stored refresh token and grant_type=refresh_token',
      () async {
    store.saved = const StoredSession(
      accessToken: 'old',
      refreshToken: 'refresh-old',
      userId: 'sub-3',
    );
    adapter.onPath('/auth/v1/token', data: _session('sub-3'));

    final result = await auth.refresh();

    final req = adapter.firstWithPath('/auth/v1/token');
    expect(req.queryParameters?['grant_type'], 'refresh_token');
    expect(req.jsonBody['refresh_token'], 'refresh-old');
    expect(result?.userId, 'sub-3');
    expect(store.saved?.accessToken, 'access-sub-3');
  });

  test('refresh with no stored session returns null without a request',
      () async {
    final result = await auth.refresh();
    expect(result, isNull);
    expect(adapter.requests, isEmpty);
  });

  test('signOut clears the stored session', () async {
    store.saved = const StoredSession(
      accessToken: 'a',
      refreshToken: 'r',
      userId: 'sub-4',
    );
    adapter.onPath('/auth/v1/logout', data: const {});
    await auth.signOut();
    expect(store.cleared, isTrue);
    expect(store.saved, isNull);
  });

  test('an auth response missing tokens raises GrobaseException', () async {
    adapter.onPath('/auth/v1/signup', data: {'user': {'id': 'x'}});
    expect(
      () => auth.signUp(email: 'a@b.com', password: 'p', username: 'u'),
      throwsA(isA<GrobaseException>()),
    );
  });
}
