// Live end-to-end round-trip for Canagrou-on-Grobase, mirroring the backend
// gate scripts/verify/m146-canagrou-roundtrip.sh from the app's own services.
//
// REQUIRES A DEVICE/EMULATOR AND A RUNNING STACK. It is NOT part of the offline
// `flutter test` suite — run it explicitly with:
//   flutter test integration_test/canagrou_roundtrip_test.dart
// against a booted emulator with the Grobase stack up and the bundled `.env`
// pointing at it (10.0.2.2 on the Android emulator, host LAN IP on a device).
import 'dart:typed_data';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:camagru_mobile/config/api_config.dart';
import 'package:camagru_mobile/services/auth_service.dart';
import 'package:camagru_mobile/services/grobase_client.dart';
import 'package:camagru_mobile/services/media_repository.dart';
import 'package:camagru_mobile/services/posts_repository.dart';
import 'package:camagru_mobile/services/token_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late GrobaseClient client;
  late AuthService auth;
  late PostsRepository posts;
  late MediaRepository media;

  setUpAll(() async {
    await dotenv.load(fileName: '.env');
    final config = BaasConfig.fromEnv();
    client = GrobaseClient(config: config);
    auth = AuthService(client, TokenStore());
    posts = PostsRepository(client);
    media = MediaRepository(client);
  });

  testWidgets('register → profile → post → like → comment → feed reflects it',
      (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final email = 'it_$stamp@canagrou.local';

    final result = await auth.signUp(
      email: email,
      password: 'ItTest!secret9',
      username: 'it_$stamp',
    );
    final userId = result.userId;
    expect(userId, isNotEmpty);

    await posts.createProfile(userId: userId, username: 'it_$stamp');

    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i % 256));
    final key = await media.uploadPost(bytes, 'png');
    final fetched = await media.fetchBytes(key);
    expect(fetched, equals(bytes));

    await posts.insertPost(userId: userId, imageKey: key);

    final feed = await posts.listFeed(currentUserId: userId);
    final mine = feed.where((p) => p.imageKey == key).toList();
    expect(mine, isNotEmpty);
    final postId = mine.first.id;

    final likeCount = await posts.toggleLike(postId, userId);
    expect(likeCount, 1);

    await posts.addComment(postId, userId, 'integration hello');
    final comments = await posts.listComments(postId);
    expect(comments.any((c) => c.content == 'integration hello'), isTrue);

    await posts.deletePost(postId);
    await media.delete(key);
  });
}
