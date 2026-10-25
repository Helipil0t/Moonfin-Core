import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/viewmodels/recordings_view_model.dart';
import 'package:moonfin/data/viewmodels/schedule_view_model.dart';
import 'package:server_core/server_core.dart';

class _Client extends Mock implements MediaServerClient {}

class _LiveTv extends Mock implements LiveTvApi {}

class _Images extends Mock implements ImageApi {}

Map<String, dynamic> timer(String id, DateTime start, {bool program = true}) =>
    {
      'Id': id,
      'Name': 'Scheduled programme',
      'ChannelName': 'Test channel',
      'Status': 'New',
      'StartDate': start.toUtc().toIso8601String(),
      'EndDate': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
      if (program)
        'ProgramInfo': {
          'Id': 'programme-id',
          'Name': 'Programme metadata',
          'TimerId': 'stale-embedded-timer-id',
          'Overview': 'Programme description',
          'ImageTags': {'Primary': 'art-tag'},
        },
    };

void main() {
  late _Client client;
  late _LiveTv liveTv;
  setUp(() {
    client = _Client();
    liveTv = _LiveTv();
    when(() => client.liveTvApi).thenReturn(liveTv);
    when(() => liveTv.cancelTimer(any())).thenAnswer((_) async {});
  });

  test(
    'timer identity survives programme metadata without changing artwork ID',
    () {
      final source = timer('timer-id', DateTime(2026, 10, 24, 20));
      final item = RecordingItem.fromTimer(TimerItem.fromJson(source));
      expect(item.id, 'programme-id');
      expect(item.timerId, 'timer-id');
      expect(item.name, 'Scheduled programme');
      expect(item.overview, 'Programme description');
      expect(item.startDate, DateTime(2026, 10, 24, 20).toUtc());
      expect(source['ProgramInfo']['TimerId'], 'stale-embedded-timer-id');

      final images = _Images();
      when(
        () => images.getPrimaryImageUrl(
          'programme-id',
          maxHeight: 300,
          tag: 'art-tag',
        ),
      ).thenReturn('programme-art');
      expect(item.imageUrl(images), 'programme-art');
    },
  );

  test('timer without ProgramInfo remains cancellable', () {
    final item = RecordingItem.fromTimer(
      TimerItem.fromJson(
        timer('timer-id', DateTime(2026, 10, 24, 20), program: false),
      ),
    );
    expect(item.timerId, 'timer-id');
    expect(item.id, 'timer-id');
    expect(item.channelName, 'Test channel');
  });

  test('ordinary completed recordings retain their item ID', () {
    final item = RecordingItem.fromJson({
      'Id': 'recording-id',
      'Name': 'Completed',
    });
    expect(item.id, 'recording-id');
    expect(item.timerId, isNull);
  });

  test(
    'cancelling one timer keeps another timer for the same programme',
    () async {
      final start = DateTime.now().add(const Duration(hours: 1));
      when(() => liveTv.getTimers()).thenAnswer(
        (_) async => {
          'Items': [timer('first', start), timer('second', start)],
        },
      );
      final vm = ScheduleViewModel(client);
      addTearDown(vm.dispose);
      await vm.load();
      final selected = vm.groups.single.items.first;
      vm.setFocusedItem(selected);
      await vm.cancelTimer(selected.timerId!);
      verify(() => liveTv.cancelTimer('first')).called(1);
      verifyNever(() => liveTv.cancelTimer('programme-id'));
      expect(vm.groups.single.items.single.timerId, 'second');
      expect(vm.focusedItem, isNull);
    },
  );

  test('a failed cancellation keeps the timer and focus', () async {
    when(() => liveTv.getTimers()).thenAnswer(
      (_) async => {
        'Items': [timer('first', DateTime.now().add(const Duration(hours: 1)))],
      },
    );
    when(() => liveTv.cancelTimer('first')).thenThrow(Exception('offline'));
    final vm = ScheduleViewModel(client);
    addTearDown(vm.dispose);
    await vm.load();
    final selected = vm.groups.single.items.single;
    vm.setFocusedItem(selected);
    await expectLater(vm.cancelTimer(selected.timerId!), throwsException);
    expect(vm.groups.single.items.single.timerId, 'first');
    expect(vm.focusedItem, same(selected));
  });

  test(
    'next-24-hours row retains timer identity and programme artwork ID',
    () async {
      when(() => liveTv.getTimers()).thenAnswer(
        (_) async => {
          'Items': [
            timer('first', DateTime.now().add(const Duration(hours: 1))),
          ],
        },
      );
      final vm = RecordingsViewModel(client);
      addTearDown(vm.dispose);
      await vm.refreshScheduled();
      expect(vm.scheduledNext24h.single.timerId, 'first');
      expect(vm.scheduledNext24h.single.id, 'programme-id');
    },
  );

  test('UTC timestamps on the same local day share the Today group', () async {
    // Run with TZ=America/Toronto to exercise timestamps on different UTC dates.
    final now = DateTime(2026, 10, 24);
    when(() => liveTv.getTimers()).thenAnswer(
      (_) async => {
        'Items': [
          timer('morning', DateTime(2026, 10, 24, 0, 30)),
          timer('evening', DateTime(2026, 10, 24, 23, 30)),
        ],
      },
    );
    final vm = ScheduleViewModel(client);
    addTearDown(vm.dispose);
    await withClock(Clock.fixed(now), vm.load);
    expect(vm.groups.single.dateLabel, 'Today');
    expect(vm.groups.single.items.map((i) => i.timerId), [
      'morning',
      'evening',
    ]);
  });

  test('opposite sides of local midnight stay in different groups', () async {
    when(() => liveTv.getTimers()).thenAnswer(
      (_) async => {
        'Items': [
          timer('tonight', DateTime(2026, 10, 24, 23, 30)),
          timer('tomorrow', DateTime(2026, 10, 25, 0, 30)),
        ],
      },
    );
    final vm = ScheduleViewModel(client);
    addTearDown(vm.dispose);
    await withClock(Clock.fixed(DateTime(2026, 10, 24, 20)), vm.load);
    expect(vm.groups.map((g) => g.dateLabel), ['Today', 'Tomorrow']);
  });

  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    test('calendar labels survive the DST transition on $day', () async {
      final nextDay = DateTime(day.year, day.month, day.day + 1);
      when(() => liveTv.getTimers()).thenAnswer(
        (_) async => {
          'Items': [timer('next-day', nextDay)],
        },
      );
      final vm = ScheduleViewModel(client);
      addTearDown(vm.dispose);
      await withClock(Clock.fixed(day), vm.load);
      expect(vm.groups.single.dateLabel, 'Tomorrow');
    });
  }
}
