import 'package:flutter/material.dart';

import 'theme.dart';

/// Placeholder home screen (full version: issue #19).
///
/// One large round Start Fajr button, a small settings icon and a small
/// practice icon. Nothing else.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _comingSoon(BuildContext context, String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what is not built yet.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Practice',
                      icon: const Icon(Icons.menu_book_outlined),
                      color: AppColors.textQuiet,
                      onPressed: () => _comingSoon(context, 'Practice mode'),
                    ),
                    IconButton(
                      tooltip: 'Settings',
                      icon: const Icon(Icons.settings_outlined),
                      color: AppColors.textQuiet,
                      onPressed: () => _comingSoon(context, 'Settings'),
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    button: true,
                    label: 'Start Fajr prayer',
                    child: SizedBox.square(
                      dimension: 200,
                      child: ElevatedButton(
                        key: const Key('start-fajr'),
                        style: ElevatedButton.styleFrom(
                          shape: const CircleBorder(),
                          backgroundColor: AppColors.surface,
                          foregroundColor: AppColors.accent,
                          side: const BorderSide(color: AppColors.accent, width: 1.5),
                        ),
                        onPressed: () => _comingSoon(context, 'Prayer tracking'),
                        child: const Text(
                          'Start Fajr',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Ad-Duha · Ash-Sharh',
                    key: Key('todays-surahs'),
                    style: TextStyle(color: AppColors.textQuiet, fontSize: 15),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
