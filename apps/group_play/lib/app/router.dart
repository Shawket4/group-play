import 'package:app_core/app_core.dart' show Routes;
import 'package:feature_home/feature_home.dart';
import 'package:feature_host/feature_host.dart';
import 'package:feature_join/feature_join.dart';
import 'package:feature_settings/feature_settings.dart';
import 'package:feature_speaker/feature_speaker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

Page<void> _page(GoRouterState s, Widget child) => CupertinoPage<void>(key: s.pageKey, child: child);

/// The one router (iOS-style pages and back-swipe on both platforms).
final routerProvider = Provider<GoRouter>((ref) {
  // Screens navigate on the result of the action they started (host → /host, join →
  // /speaker, end/leave → /), so there is no role redirect: the status stream lags an action by
  // up to 250 ms and would bounce a screen that just opened.
  final router = GoRouter(
    routes: [
      GoRoute(
        path: Routes.home,
        pageBuilder: (c, s) => _page(s, const HomeScreen()),
        routes: [
          GoRoute(
            path: 'host',
            pageBuilder: (c, s) => _page(s, const HostScreen()),
            routes: [
              GoRoute(
                path: Routes.hostSpeakerPattern,
                pageBuilder: (c, s) => _page(s, SpeakerDetailScreen(id: s.pathParameters['id']!)),
              ),
            ],
          ),
          GoRoute(path: 'join', pageBuilder: (c, s) => _page(s, const JoinScreen())),
          GoRoute(path: 'speaker', pageBuilder: (c, s) => _page(s, const SpeakerScreen())),
          GoRoute(
            path: 'settings',
            pageBuilder: (c, s) => _page(s, const SettingsScreen()),
            routes: [
              GoRoute(path: 'name', pageBuilder: (c, s) => _page(s, const NameScreen())),
              GoRoute(path: 'capture', pageBuilder: (c, s) => _page(s, const CaptureSetupScreen())),
              GoRoute(path: 'logs', pageBuilder: (c, s) => _page(s, const LogsScreen())),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
