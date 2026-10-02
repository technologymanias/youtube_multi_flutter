import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/youtube_sync.dart';

void main() {
  // These cases stay offline on purpose: everything that reaches the network
  // needs a token, so the paths below can never trigger a request.
  test('an empty probe round reports nothing rather than everything deleted',
      () async {
    final verdict = await YoutubeSync.verifyUploads('token', const []);
    expect(verdict, isNotNull);
    expect(verdict!.present, isEmpty);
    expect(verdict.absent, isEmpty);
  });

  test('without a token no answer is given, so the caller keeps its badges',
      () async {
    const probes = [
      YoutubeUploadProbe(key: 'job', videoId: 'abc', title: 'Title'),
    ];
    expect(await YoutubeSync.verifyUploads(null, probes), isNull);
    expect(await YoutubeSync.verifyUploads('', probes), isNull);
  });

  test('a probe with neither an id nor a title cannot be judged', () async {
    // Both probes are unverifiable, so nothing may be decided — a round that
    // learns nothing must not look like a round that proved deletion.
    const probes = [
      YoutubeUploadProbe(key: 'a'),
      YoutubeUploadProbe(key: 'b', videoId: '   ', title: '  '),
    ];
    expect(await YoutubeSync.verifyUploads('token', probes), isNull);
  });
}
