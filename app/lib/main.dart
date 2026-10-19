import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import 'src/screens/home_page.dart';
import 'src/screens/setup_flow.dart';
import 'src/services/app_services.dart';
import 'src/services/demo.dart';
import 'src/services/real_services.dart';
import 'src/theme.dart';

/// `flutter run --dart-define=DEMO=true` runs the scripted demo services
/// (no camera, no audio) on any device.
const bool demoMode = bool.fromEnvironment('DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const app = SalahCompanionApp();
  // The pose engine is Android only; elsewhere (desktop, web) run the demo.
  if (demoMode || defaultTargetPlatform != TargetPlatform.android) {
    runApp(DemoServices.wrap(child: app));
    return;
  }
  final services = await RealServices.load();
  runApp(services.wrap(child: app));
}

/// The app. Expects an [AppServices] above it.
class SalahCompanionApp extends StatelessWidget {
  const SalahCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Salah Companion',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const AppRoot(),
    );
  }
}

/// Shows first-run setup once, then Home.
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  Future<(bool, SessionSettings)>? _boot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _boot ??= () async {
      final store = AppServices.of(context).settingsStore;
      return (await store.isSetupDone(), await store.load());
    }();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(bool, SessionSettings)>(
      future: _boot,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          return const ColoredBox(color: AppColors.background);
        }
        final (done, settings) = data;
        return done ? const HomePage() : SetupFlow(initial: settings);
      },
    );
  }
}
