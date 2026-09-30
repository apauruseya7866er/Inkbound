import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/backup/backup_folder.dart';
import 'package:watch_app/core/backup/backup_service.dart';
import 'package:watch_app/core/backup/library_backup.dart';
import 'package:watch_app/core/backup/settings_backup.dart';
import 'package:watch_app/core/backup/sources_backup.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/backup/backup_screen.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubRegistry implements ProviderRegistry {
  @override
  List<ProviderRegistryEntry> getAll() => const [];
  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;
  @override
  Set<String> nsfwSourceIds() => const {};
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubReposRegistry implements ProviderReposRegistry {
  @override
  List<ProviderRepo> getAll() => const [];
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// A REAL temp dir path_provider is mocked to, because writing a backup stages
// the JSON in the temp dir before moving it into the folder.
late Directory _appDir;

void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => _appDir.path,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() async {
    _appDir = Directory.systemTemp.createTempSync('backup_test');
    // Mock path_provider before anything asks for a real one.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => _appDir.path);
    Hive.init('${_appDir.path}/hive');
    await BackupFolderPrefs.init();
    sl
      ..registerSingleton<AppMode>(const AppMode(isTv: false))
      ..registerSingleton<BackupService>(BackupService(
        SourcesBackup(_StubReposRegistry(), _StubRegistry(), null),
        LibraryBackup(),
        SettingsBackup(),
      ))
      ..registerSingleton<BackupFolderPrefs>(BackupFolderPrefs())
      ..registerSingleton<BackupFolder>(
        BackupFolder(BackupFolderPrefs()),
      );
  });

  tearDown(() async {
    sl.reset();
    await Hive.deleteFromDisk();
    if (_appDir.existsSync()) _appDir.deleteSync(recursive: true);
  });

  Future<void> pumpBackup(WidgetTester tester) async {
    _mockPathProvider(tester);
    // Tall surface so the lazy ListView builds every tile (the screen is
    // longer than the default 800px test viewport).
    await tester.binding.setSurfaceSize(const Size(1000, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: BackupScreen()));
    await tester.pump();
  }

  testWidgets(
    'BackupScreen offers local backups only - no cloud, no sign-in',
    (tester) async {
      await pumpBackup(tester);

      // Three bundle checkboxes (all checked by default).
      expect(find.text('Sources & repos'), findsOneWidget);
      expect(find.text('Library'), findsOneWidget);
      expect(find.text('App settings'), findsOneWidget);

      // A folder is the automatic destination, a file is the manual one.
      expect(find.text('Back up to a folder'), findsOneWidget);
      expect(find.text('Save to a file'), findsOneWidget);
      expect(find.text('Restore from a file'), findsOneWidget);

      // The account-backed half of this screen is gone for good.
      expect(find.text('Back up to cloud'), findsNothing);
      expect(find.text('Restore from cloud'), findsNothing);
      expect(find.text('Sign in'), findsNothing);
    },
  );

  testWidgets('with no folder picked, the automatic controls stay hidden',
      (tester) async {
    await pumpBackup(tester);

    // Nothing to turn on, back up now, or stop until a folder exists.
    expect(find.text('Back up now'), findsNothing);
    expect(find.text('Back up automatically'), findsNothing);
    expect(find.text('Stop backing up to this folder'), findsNothing);
    // ...and the tile explains how to get one.
    expect(find.textContaining('Pick once'), findsOneWidget);
  });

  testWidgets('a picked folder reveals the automatic controls and its label',
      (tester) async {
    // Real Hive I/O inside testWidgets has to go through runAsync - the fake
    // async zone never lets the box's disk write complete otherwise (and the
    // hang looks like a build loop, not a stuck write).
    await tester.runAsync(() => BackupFolderPrefs().setFolder(
          'content://com.android.externalstorage.documents/tree/primary%3ABackups',
          'Internal storage › Backups',
        ));
    await pumpBackup(tester);

    expect(find.text('Back up automatically'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Stop backing up to this folder'), findsOneWidget);
    // The tile names the real folder, so it can't misdescribe the target.
    expect(find.text('Internal storage › Backups'), findsOneWidget);
    // Retention is stated, including that other files are spared.
    expect(find.textContaining('never touched'), findsOneWidget);
  });

  testWidgets('TV: backup rows are wrapped in TvFocusable', (tester) async {
    sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    await pumpBackup(tester);
    // Bundle checkbox rows + action tiles are all focusable rows.
    expect(
      tester.widgetList<TvFocusable>(find.byType(TvFocusable)).length,
      greaterThanOrEqualTo(4),
    );
  });

  testWidgets('phone: BackupScreen adds no TvFocusable (unchanged)',
      (tester) async {
    // setUp registered AppMode(isTv: false) — phone path.
    await pumpBackup(tester);
    expect(find.byType(TvFocusable), findsNothing);
  });
}
