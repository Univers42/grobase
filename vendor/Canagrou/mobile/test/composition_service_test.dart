import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ComputeCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:camagru_mobile/services/composition_service.dart';

/// Encodes a solid [w]x[h] PNG so the compositor has real image bytes to decode.
Uint8List _png(int w, int h, int r, int g, int b, int a) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(r, g, b, a));
  return Uint8List.fromList(img.encodePng(image));
}

/// Runs the isolate callback inline so the test needs no real isolate/asset.
Future<R> _inlineRunner<R, M>(ComputeCallback<M, R> fn, M message) async {
  return fn(message);
}

void main() {
  late CompositionService service;
  late Uint8List overlay;

  setUp(() {
    overlay = _png(1, 1, 0, 0, 0, 128); // semi-transparent overlay
    service = CompositionService(
      loadAsset: (_) async => overlay,
      runner: _inlineRunner,
    );
  });

  test('compositePhoto produces non-empty, decodable PNG bytes', () async {
    final frame = _png(1, 1, 255, 0, 0, 255);
    final out = await service.compositePhoto(frame, 'assets/overlays/x.png');
    expect(out, isNotEmpty);
    final decoded = img.decodeImage(out);
    expect(decoded, isNotNull);
    expect(decoded!.width, 1);
    expect(decoded.height, 1);
  });

  test('compositePhoto with mirror still yields valid bytes', () async {
    final frame = _png(2, 1, 0, 255, 0, 255);
    final out = await service.compositePhoto(
      frame,
      'assets/overlays/x.png',
      mirror: true,
    );
    expect(out, isNotEmpty);
    expect(img.decodeImage(out), isNotNull);
  });

  test('compositeGif builds an animated GIF from multiple frames', () async {
    final frames = [
      _png(1, 1, 255, 0, 0, 255),
      _png(1, 1, 0, 0, 255, 255),
    ];
    final out = await service.compositeGif(frames, 'assets/overlays/x.png');
    expect(out, isNotEmpty);
    final decoded = img.decodeGif(out);
    expect(decoded, isNotNull);
    expect(decoded!.numFrames, 2);
  });

  test('compositeGif rejects an empty frame list', () async {
    expect(
      () => service.compositeGif(const [], 'assets/overlays/x.png'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
