import 'package:flutter/material.dart';

import '../services/phone_data_service.dart';
import 'phone_data_list_page.dart';

/// The C / L / N / T letter buttons that sit next to the V/P/F media
/// filters in an app bar. Unlike the VPF tabs (which swap the grid in
/// place) these push their own list screen, since each shows a different
/// phone-data category.
///
/// Usage inside an `AppBar(actions: [...])`:
///   `...phoneDataBarButtons(context, accent: Colors.green),`
List<Widget> phoneDataBarButtons(
  BuildContext context, {
  required Color accent,
  List<PhoneDataKind> kinds = PhoneDataKind.values,
}) {
  return [
    for (final kind in kinds)
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: kind.title,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PhoneDataListPage(
                  kind: kind,
                  accent: accent,
                ),
              ),
            ),
            child: LetterBadge(letter: kind.letter, accent: accent),
          ),
        ),
      ),
  ];
}
