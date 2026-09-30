import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/backup/backup_folder.dart';

void main() {
  group('isAutoBackupDue', () {
    final now = DateTime(2026, 7, 2, 9, 0);

    test('a folder that has never been backed up is due immediately', () {
      // Otherwise picking a folder would leave it empty for a day.
      expect(isAutoBackupDue(lastBackupAt: null, now: now), isTrue);
    });

    test('a recent backup is not due', () {
      expect(
        isAutoBackupDue(
          lastBackupAt: now.subtract(const Duration(hours: 3)),
          now: now,
        ),
        isFalse,
      );
    });

    test('exactly one interval old is due', () {
      expect(
        isAutoBackupDue(
          lastBackupAt: now.subtract(kAutoBackupInterval),
          now: now,
        ),
        isTrue,
      );
    });

    test('older than the interval is due', () {
      expect(
        isAutoBackupDue(
          lastBackupAt: now.subtract(const Duration(days: 3)),
          now: now,
        ),
        isTrue,
      );
    });

    test('a failed write is retried rather than skipped for a day', () {
      // lastBackupAt only moves on a successful write, so a folder whose
      // permission was revoked doesn't go quiet for 24h after one failure.
      final longAgo = now.subtract(const Duration(days: 30));
      expect(
        isAutoBackupDue(lastBackupAt: longAgo, now: now),
        isTrue,
      );
    });

    test('a custom interval is honoured', () {
      expect(
        isAutoBackupDue(
          lastBackupAt: now.subtract(const Duration(hours: 2)),
          now: now,
          interval: const Duration(hours: 1),
        ),
        isTrue,
      );
      expect(
        isAutoBackupDue(
          lastBackupAt: now.subtract(const Duration(minutes: 30)),
          now: now,
          interval: const Duration(hours: 1),
        ),
        isFalse,
      );
    });
  });

  group('isBackupFileName', () {
    test('accepts a written backup', () {
      expect(isBackupFileName('zangetsu-backup-20260702-0900.json'), isTrue);
    });

    test('rejects other files in the same folder', () {
      // A picked folder is a real folder. The rolling window must never eat
      // something the app didn't write.
      expect(isBackupFileName('holiday.jpg'), isFalse);
      expect(isBackupFileName('zangetsu-backup-notes.json'), isFalse);
      expect(isBackupFileName('zangetsu-backup-2026070.json'), isFalse);
      expect(isBackupFileName('notes-zangetsu-backup-20260702-0900.json'), isFalse);
      expect(isBackupFileName('zangetsu-backup-20260702-0900.json.txt'), isFalse);
    });
  });

  group('prunePlan', () {
    String n(int day, int hour) =>
        'zangetsu-backup-202607${day.toString().padLeft(2, '0')}-'
        '${hour.toString().padLeft(2, '0')}00.json';

    test('keeps the newest N and deletes the rest, oldest first', () {
      final plan = prunePlan([n(1, 9), n(5, 9), n(3, 9), n(2, 9)], keep: 2);
      // Names embed the stamp, so string order is time order.
      expect(plan, [n(1, 9), n(2, 9)]);
    });

    test('deletes nothing when at or under the limit', () {
      expect(prunePlan([n(1, 9), n(2, 9)], keep: 2), isEmpty);
      expect(prunePlan(const [], keep: 5), isEmpty);
    });

    test('ignores files the app did not write', () {
      final plan = prunePlan(
        [n(1, 9), n(2, 9), 'holiday.jpg', 'novels.txt'],
        keep: 1,
      );
      expect(plan, [n(1, 9)]);
    });

    test('keep 0 clears the folder of its backups', () {
      final plan = prunePlan([n(1, 9), n(2, 9)], keep: 0);
      expect(plan, [n(1, 9), n(2, 9)]);
    });

    test('a negative keep is a no-op rather than a wipe', () {
      expect(prunePlan([n(1, 9)], keep: -1), isEmpty);
    });

    test('sorts by name, not by the order the platform listed them', () {
      // SAF listFiles() order is provider-defined and must not decide what
      // gets deleted.
      final plan = prunePlan([n(9, 9), n(1, 9), n(5, 9)], keep: 1);
      expect(plan, [n(1, 9), n(5, 9)]);
    });
  });
}
