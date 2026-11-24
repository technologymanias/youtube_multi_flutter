import 'package:flutter/foundation.dart';

/// The phone-data categories exposed next to the media filters (V/P/F).
/// `logs` is local-only for now; contacts / notes / texts appear on both
/// the Local and Telegram bars.
enum PhoneDataKind {
  contacts('C', 'Contacts'),
  logs('L', 'Call Logs'),
  notes('N', 'Notes'),
  texts('T', 'Text Messages');

  final String letter;
  final String title;
  const PhoneDataKind(this.letter, this.title);
}

/// One row shown on a phone-data list screen.
class PhoneDataItem {
  final String id;
  final String title;
  final String? subtitle;
  final String? trailing;

  const PhoneDataItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.trailing,
  });
}

/// Single entry point the C/L/N/T screens read from.
///
/// The real phone readers (contacts / call-log / notes / SMS plugins, or a
/// file the user supplies later) get plugged in here — the list screens and
/// the bar buttons are already wired and only depend on [load]. Until then
/// every category answers with an empty list so the UI is fully navigable.
class PhoneDataService {
  PhoneDataService._();
  static final PhoneDataService instance = PhoneDataService._();

  /// Set once a real reader is available; falls back to empty lists.
  Future<List<PhoneDataItem>> Function(PhoneDataKind kind)? reader;

  Future<List<PhoneDataItem>> load(PhoneDataKind kind) async {
    final r = reader;
    if (r == null) {
      debugPrint('PhoneDataService: no reader connected for ${kind.name}');
      return const [];
    }
    return r(kind);
  }
}
