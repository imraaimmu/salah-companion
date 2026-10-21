import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:salah_core/salah_core.dart';

import 'src/screens/home_page.dart';
import 'src/screens/setup_flow.dart';
import 'src/services/app_services.dart';
import 'src/services/demo.dart';
import 'src/services/real_services.dart';
import 'src/services/seams.dart';
import 'src/theme.dart';

/// `flutter run --dart-define=DEMO=true` runs the scripted demo services
/// (no camera, no audio) on any device.
const bool demoMode = bool.fromEnvironment('DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Release builds show a blank grey box when a screen fails to build. Show
  // the error in words instead, so a tester can read it out (nothing is
  // sent anywhere).
  ErrorWidget.builder = (details) =>
      StartupProblem(details.exceptionAsString());
  const app = SalahCompanionApp();
  // The pose engine is Android only; elsewhere (desktop, web) run the demo.
  if (demoMode || defaultTargetPlatform != TargetPlatform.android) {
    runApp(DemoServices.wrap(child: app));
    return;
  }
  final RealServices services;
  try {
    services = await RealServices.load();
  } catch (e) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: StartupProblem('$e'),
      ),
    );
    return;
  }
  runApp(services.wrap(child: app));
}

/// A readable error screen, used instead of a blank screen.
class StartupProblem extends StatelessWidget {
  final String message;
  const StartupProblem(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Something went wrong while opening the app.\n\n$message',
            textAlign: TextAlign.center,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
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
    _boot ??= loadBootState(AppServices.of(context).settingsStore);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(bool, SessionSettings)>(
      future: _boot,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) {
          return const ColoredBox(
            color: AppColors.background,
            child: Center(
              child: SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.textQuiet,
                ),
              ),
            ),
          );
        }
        final (done, settings) = data;
        return done ? const HomePage() : SetupFlow(initial: settings);
      },
    );
  }
}

/// Reads whether setup is done and the saved settings.
///
/// Never fails and never hangs: if the settings storage throws or takes
/// longer than [timeout], the app starts with defaults (first-run setup)
/// instead of staying on a blank screen.
Future<(bool, SessionSettings)> loadBootState(
  SettingsStore store, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  try {
    return await Future(() async {
      return (await store.isSetupDone(), await store.load());
    }).timeout(timeout);
  } catch (_) {
    return (false, const SessionSettings());
  }
}
