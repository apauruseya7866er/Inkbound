import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/seed_repo.dart';

/// Covers the first-run seeding of the official LNReader plugin repo.
///
/// This is the piece that makes a novel-only install usable: the app always had
/// the index/install pipeline, but nothing put a repo URL in the box, so a fresh
/// install had zero novel sources.
///
/// Deliberately no network — the published index is injected as a fake, so this
/// pins OUR logic (which entries get installed, which are left alone, what
/// happens on a partial failure) rather than upstream's availability.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('lnreader_seed_test');
    Hive.init(tmpDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  /// A fake index in the exact published shape (`LnReaderPluginMeta.fromMap`).
  String indexJson(List<Map<String, String>> entries) {
    final b = StringBuffer('[');
    for (var i = 0; i < entries.length; i++) {
      if (i > 0) b.write(',');
      b.write('{');
      b.write(entries[i].entries
          .map((kv) => '"${kv.key}":"${kv.value}"')
          .join(','));
      b.write('}');
    }
    b.write(']');
    return b.toString();
  }

  /// `url` is nullable rather than defaulting off `id`, because a Dart default
  /// value cannot reference another parameter. Empty means "malformed entry",
  /// which the installer must skip.
  Map<String, String> entry(
    String id, {
    String lang = 'English',
    String version = '1.0.0',
    String? url,
  }) => {
    'id': id,
    'name': 'Name $id',
    'site': 'https://$id.test/',
    'lang': lang,
    'version': version,
    'url': url ?? 'https://cdn.test/$id.js',
    'iconUrl': '',
  };

  /// Records every JS download so we can assert what was and wasn't fetched.
  ({LnReaderExtensionService service, List<String> fetched}) build({
    required String index,
    List<String> failFor = const [],
  }) {
    final fetched = <String>[];
    final service = LnReaderExtensionService(httpGet: (url) async {
      if (url == LnReaderSeedRepo.indexUrl) return index;
      final id = url.split('/').last.replaceAll('.js', '');
      fetched.add(id);
      if (failFor.contains(id)) throw StateError('boom $id');
      return 'module.exports.default={name:"$id"};';
    });
    return (service: service, fetched: fetched);
  }

  group('repo seeding', () {
    test('adds the official index URL to the tracked repos', () async {
      final added = await LnReaderSeedRepo.ensureSeeded();
      expect(added, isTrue);
      final box = Hive.box<String>(LnReaderSeedRepo.reposBoxName);
      expect(box.values, contains(LnReaderSeedRepo.indexUrl));
    });

    test('is idempotent - a second launch does not duplicate the URL', () async {
      await LnReaderSeedRepo.ensureSeeded();
      final again = await LnReaderSeedRepo.ensureSeeded();
      expect(again, isFalse);
      final box = Hive.box<String>(LnReaderSeedRepo.reposBoxName);
      expect(box.values.where((u) => u == LnReaderSeedRepo.indexUrl).length, 1);
    });

    test('leaves a user-added repo alone', () async {
      await Hive.openBox<String>(LnReaderSeedRepo.reposBoxName);
      final box = Hive.box<String>(LnReaderSeedRepo.reposBoxName);
      await box.add('https://example.test/my-plugins.min.json');
      await LnReaderSeedRepo.ensureSeeded();
      expect(box.values, contains('https://example.test/my-plugins.min.json'));
      expect(box.values, contains(LnReaderSeedRepo.indexUrl));
    });
  });

  group('English install pass', () {
    test('installs only the English sources', () async {
      final f = build(
        index: indexJson([
          entry('alpha'),
          entry('bravo'),
          entry('gamma', lang: 'Français'),
          entry('delta', lang: 'Spanish'),
        ]),
      );
      final written = await LnReaderSeedRepo.installLanguage(f.service);
      expect(written, ['alpha', 'bravo']);
      final box = Hive.box<Map>(LnReaderExtensionService.boxName);
      expect(box.keys.toSet(), {'alpha', 'bravo'});
    });

    test('installed entries carry the JS so they run offline afterwards',
        () async {
      final f = build(index: indexJson([entry('alpha')]));
      await LnReaderSeedRepo.installLanguage(f.service);
      final js = Hive.box<Map>(LnReaderExtensionService.boxName).get('alpha');
      expect(js?['js'], contains('module.exports.default'));
      expect(f.fetched, ['alpha']);
    });

    test('skips one already installed at the same version', () async {
      final f = build(index: indexJson([entry('alpha', version: '1.0.0')]));
      await LnReaderSeedRepo.installLanguage(f.service);
      f.fetched.clear();
      final written = await LnReaderSeedRepo.installLanguage(f.service);
      expect(written, isEmpty);
      expect(f.fetched, isEmpty, reason: 'no needless re-download');
    });

    test('refreshes an installed source when the index is newer', () async {
      final f = build(index: indexJson([entry('alpha', version: '1.0.0')]));
      await LnReaderSeedRepo.installLanguage(f.service);
      f.fetched.clear();

      // Same id, bumped version.
      final f2 = build(index: indexJson([entry('alpha', version: '1.1.0')]));
      final written = await LnReaderSeedRepo.installLanguage(f2.service);
      expect(written, ['alpha']);
      expect(f2.fetched, ['alpha']);
    });

    test('does NOT downgrade when the installed copy is newer', () async {
      final f = build(index: indexJson([entry('alpha', version: '2.0.0')]));
      await LnReaderSeedRepo.installLanguage(f.service);
      f.fetched.clear();

      final f2 = build(index: indexJson([entry('alpha', version: '1.9.0')]));
      final written = await LnReaderSeedRepo.installLanguage(f2.service);
      expect(written, isEmpty, reason: 'an older index must not clobber');
      expect(f2.fetched, isEmpty);
    });

    test('resumes: a partially-completed run finishes the rest', () async {
      final f = build(
        index: indexJson([entry('a'), entry('b'), entry('c')]),
        failFor: ['b'],
      );
      final first = await LnReaderSeedRepo.installLanguage(f.service);
      // a installed, b failed, c still attempted.
      expect(first, isNot(contains('b')));
      expect(first, contains('a'));
      expect(first, contains('c'));

      // Next launch: b is retried, a and c are left alone.
      f.fetched.clear();
      final f2 = build(index: indexJson([entry('a'), entry('b'), entry('c')]));
      final second = await LnReaderSeedRepo.installLanguage(f2.service);
      expect(second, ['b']);
      expect(f2.fetched, ['b']);
    });

    test('a dead site does not abandon the rest of the index', () async {
      final f = build(
        index: indexJson([entry('good'), entry('bad')]),
        failFor: ['bad'],
      );
      final written = await LnReaderSeedRepo.installLanguage(f.service);
      expect(written, contains('good'));
      expect(written, isNot(contains('bad')));
    });

    test('an unreachable index is not fatal', () async {
      final service = LnReaderExtensionService(
        httpGet: (_) async => throw StateError('offline'),
      );
      final written = await LnReaderSeedRepo.installLanguage(service);
      expect(written, isEmpty);
    });

    test('skips a malformed entry rather than writing junk', () async {
      final f = build(
        index: indexJson([
          entry('nourl', url: ''),
          entry('ok'),
        ]),
      );
      final written = await LnReaderSeedRepo.installLanguage(f.service);
      expect(written, ['ok']);
      final box = Hive.box<Map>(LnReaderExtensionService.boxName);
      expect(box.get('nourl'), isNull);
    });
  });
}
