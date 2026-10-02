import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
    androidConfiguration: AndroidConfiguration(
      autoStart: false,
      onStart: onStart,
      isForegroundMode: false,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) {
  // Keeps the process alive for background execution
  service.on('process_queue').listen((event) {});
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

Future<void> updateBadgeCount(int count) async {
  if (count > 0) {
    try {
      await FlutterAppBadger.updateBadgeCount(count);
    } catch (_) {}
  } else {
    try {
      // Awaited, like the branch above: an unawaited plugin call leaves its
      // error uncaught the moment the badge is cleared on a platform where
      // the plugin does nothing.
      await FlutterAppBadger.removeBadge();
    } catch (_) {}
  }
}
