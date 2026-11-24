import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/master/master_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android is told whether Flutter accepted the message', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var ready = false;
    MasterPlatform(onServiceAction: (_) {}, onMessage: (_) => ready);
    const codec = StandardMethodCodec();
    Future<dynamic> post() async {
      dynamic result;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'jarvis/master',
        codec.encodeMethodCall(const MethodCall('socialPosted', {'key': 'message-1'})),
        (reply) => result = codec.decodeEnvelope(reply!),
      );
      return result;
    }

    expect(await post(), isFalse);
    ready = true;
    expect(await post(), isTrue);
  });
}
