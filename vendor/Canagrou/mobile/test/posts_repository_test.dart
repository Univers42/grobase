import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camagru_mobile/services/grobase_client.dart';
import 'package:camagru_mobile/services/posts_repository.dart';
import 'support/recording_adapter.dart';

void main() {
  late RecordingAdapter adapter;
  late GrobaseClient client;
  late PostsRepository repo;

  setUp(() {
    adapter = RecordingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
      ..httpClientAdapter = adapter;
    client = GrobaseClient(config: testConfig(), dio: dio);
    repo = PostsRepository(client);
  });

  test('every /query request carries apikey and X-Baas-Api-Key headers',
      () async {
    adapter.onPath('/tables/profiles', data: {'rows': []});
    await repo.getProfile('u1');
    final req = adapter.firstWithPath('/query/v1/db-uuid/tables/profiles');
    expect(req.path, '/query/v1/db-uuid/tables/profiles');
    expect(req.headers['apikey'], 'anon-key');
    expect(req.headers['X-Baas-Api-Key'], 'mbk_test_key');
  });

  test('insertPost sends op=insert with user_id + image_key and no id',
      () async {
    adapter.onPath('/tables/posts', status: 201, data: {'rows': []});
    await repo.insertPost(userId: 'u1', imageKey: 'abc.png');
    final body = adapter.firstWithPath('/tables/posts').jsonBody;
    expect(body['op'], 'insert');
    expect(body['data'], {'user_id': 'u1', 'image_key': 'abc.png'});
    expect((body['data'] as Map).containsKey('id'), isFalse);
  });

  test('listFeed sends list sorted by created_at desc with paging', () async {
    adapter.on(
      (o) => o.path.contains('/tables/posts'),
      data: {
        'rows': [
          {'id': 7, 'user_id': 'u1', 'image_key': 'a.png', 'created_at': 't'},
        ],
      },
    );
    adapter.onPath('/tables/profiles', data: {
      'rows': [
        {'id': 'u1', 'username': 'alice'},
      ],
    });
    adapter.onPath('/tables/likes', data: {
      'rows': [
        {'id': 1, 'user_id': 'u1', 'post_id': 7},
      ],
    });
    adapter.onPath('/tables/comments', data: {'rows': []});

    final feed = await repo.listFeed(limit: 5, offset: 10, currentUserId: 'u1');

    final postsReq = adapter.firstWithPath('/tables/posts');
    expect(postsReq.jsonBody['op'], 'list');
    expect(postsReq.jsonBody['limit'], 5);
    expect(postsReq.jsonBody['offset'], 10);
    expect(postsReq.jsonBody['sort'], {'created_at': 'desc'});

    expect(feed, hasLength(1));
    expect(feed.first.id, 7);
    expect(feed.first.author, 'alice');
    expect(feed.first.imageKey, 'a.png');
    expect(feed.first.likesCount, 1);
    expect(feed.first.likedByMe, isTrue);
  });

  test('toggleLike inserts when no like exists, then returns a count',
      () async {
    // Every likes query replies with no rows: the first (existence) list is
    // empty → insert path; the final count list is also empty → count 0.
    adapter.onPath('/tables/likes', status: 201, data: {'rows': []});

    final count = await repo.toggleLike(7, 'u1');

    final insert = adapter.requests.firstWhere(
      (r) => r.path.contains('/tables/likes') && r.jsonBody['op'] == 'insert',
    );
    expect(insert.jsonBody['data'], {'user_id': 'u1', 'post_id': 7});
    expect(count, 0);
  });

  test('addComment sends op=insert with the content', () async {
    adapter.onPath('/tables/comments', status: 201, data: {'rows': []});
    await repo.addComment(7, 'u1', 'hello world');
    final body = adapter.firstWithPath('/tables/comments').jsonBody;
    expect(body['op'], 'insert');
    expect(body['data'],
        {'user_id': 'u1', 'post_id': 7, 'content': 'hello world'});
  });

  test('createProfile keys the row by the GoTrue sub', () async {
    adapter.onPath('/tables/profiles', status: 201, data: {'rows': []});
    await repo.createProfile(userId: 'sub-123', username: 'bob');
    final body = adapter.firstWithPath('/tables/profiles').jsonBody;
    expect(body['op'], 'insert');
    expect(body['data'],
        {'id': 'sub-123', 'username': 'bob', 'notify_comments': true});
  });

  test('a non-2xx /query reply surfaces as GrobaseException', () async {
    adapter.onPath('/tables/posts', status: 402, data: {'msg': 'quota'});
    expect(
      () => repo.insertPost(userId: 'u1', imageKey: 'x.png'),
      throwsA(isA<GrobaseException>()),
    );
  });
}
