import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// ===== core/models.dart =====
DateTime? _dt(dynamic v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;

String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime plusDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// Max notifications scheduled per series (id = base * 64 + index).
const int kMaxSeries = 60;

class Task {
  int id;
  String title;
  String note;
  DateTime due;
  int repeatMin; // 0 = once
  int priority; // 0 low, 1 medium, 2 high
  String status; // active | done | deleted
  DateTime created;
  DateTime? completedAt;
  DateTime? loggedUntil;

  Task({
    required this.id,
    required this.title,
    this.note = '',
    required this.due,
    this.repeatMin = 0,
    this.priority = 1,
    this.status = 'active',
    DateTime? created,
    this.completedAt,
    this.loggedUntil,
  }) : created = created ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'note': note,
        'due': _ms(due),
        'repeatMin': repeatMin,
        'priority': priority,
        'status': status,
        'created': _ms(created),
        'completedAt': _ms(completedAt),
        'loggedUntil': _ms(loggedUntil),
      };

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as int,
        title: j['title'] as String,
        note: (j['note'] as String?) ?? '',
        due: _dt(j['due'])!,
        repeatMin: (j['repeatMin'] as int?) ?? 0,
        priority: (j['priority'] as int?) ?? 1,
        status: (j['status'] as String?) ?? 'active',
        created: _dt(j['created']),
        completedAt: _dt(j['completedAt']),
        loggedUntil: _dt(j['loggedUntil']),
      );

  /// Future reminder times (from [from], default now).
  List<DateTime> occurrences({DateTime? from, int max = kMaxSeries}) {
    final f = from ?? DateTime.now();
    final out = <DateTime>[];
    if (repeatMin <= 0) {
      if (due.isAfter(f)) out.add(due);
      return out;
    }
    var t = due;
    if (t.isBefore(f)) {
      final diff = f.difference(t).inMinutes;
      final k = (diff / repeatMin).ceil();
      t = due.add(Duration(minutes: k * repeatMin));
    }
    while (out.length < max) {
      out.add(t);
      t = t.add(Duration(minutes: repeatMin));
    }
    return out;
  }

  /// Reminder times that already passed and were not logged yet.
  List<DateTime> elapsed(DateTime now) {
    if (due.isAfter(now)) return [];
    if (repeatMin <= 0) return loggedUntil == null ? [due] : [];
    var k = 0;
    if (loggedUntil != null) {
      k = loggedUntil!.difference(due).inMinutes ~/ repeatMin + 1;
    }
    final out = <DateTime>[];
    var t = due.add(Duration(minutes: k * repeatMin));
    while (!t.isAfter(now) && out.length < 500) {
      out.add(t);
      t = t.add(Duration(minutes: repeatMin));
    }
    return out.length > 8 ? out.sublist(out.length - 8) : out;
  }
}

class NotifItem {
  int id;
  String title;
  String body;
  DateTime at;
  String source; // custom | task
  String status; // pending | delivered | cancelled

  NotifItem({
    required this.id,
    required this.title,
    this.body = '',
    required this.at,
    this.source = 'custom',
    this.status = 'pending',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'at': _ms(at),
        'source': source,
        'status': status,
      };

  factory NotifItem.fromJson(Map<String, dynamic> j) => NotifItem(
        id: j['id'] as int,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        at: _dt(j['at'])!,
        source: (j['source'] as String?) ?? 'custom',
        status: (j['status'] as String?) ?? 'pending',
      );
}

class Habit {
  int id;
  String name;
  String emoji;
  Set<String> done;
  int? remindMin; // minutes since midnight

  Habit({
    required this.id,
    required this.name,
    this.emoji = '🎯',
    Set<String>? done,
    this.remindMin,
  }) : done = done ?? <String>{};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'done': done.toList(),
        'remindMin': remindMin,
      };

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
        id: j['id'] as int,
        name: j['name'] as String,
        emoji: (j['emoji'] as String?) ?? '🎯',
        done: ((j['done'] as List?) ?? []).map((e) => e as String).toSet(),
        remindMin: j['remindMin'] as int?,
      );

  int get streak {
    var d = DateTime.now();
    if (!done.contains(dayKey(d))) d = plusDays(d, -1);
    var n = 0;
    while (done.contains(dayKey(d))) {
      n++;
      d = plusDays(d, -1);
    }
    return n;
  }
}

class StudySession {
  String subject;
  int minutes;
  DateTime at;
  StudySession({required this.subject, required this.minutes, required this.at});

  Map<String, dynamic> toJson() => {'subject': subject, 'minutes': minutes, 'at': _ms(at)};
  factory StudySession.fromJson(Map<String, dynamic> j) => StudySession(
        subject: j['subject'] as String,
        minutes: j['minutes'] as int,
        at: _dt(j['at'])!,
      );
}

class Expense {
  int id;
  double amount;
  String category;
  String note;
  DateTime at;
  Expense({required this.id, required this.amount, required this.category, this.note = '', required this.at});

  Map<String, dynamic> toJson() =>
      {'id': id, 'amount': amount, 'category': category, 'note': note, 'at': _ms(at)};
  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] as int,
        amount: (j['amount'] as num).toDouble(),
        category: j['category'] as String,
        note: (j['note'] as String?) ?? '',
        at: _dt(j['at'])!,
      );
}

class Exam {
  int id;
  String subject;
  DateTime at;
  Exam({required this.id, required this.subject, required this.at});

  Map<String, dynamic> toJson() => {'id': id, 'subject': subject, 'at': _ms(at)};
  factory Exam.fromJson(Map<String, dynamic> j) =>
      Exam(id: j['id'] as int, subject: j['subject'] as String, at: _dt(j['at'])!);
}

class Upcoming {
  final String title;
  final String source; // custom | task | habit | exam
  final DateTime at;
  final int? notifId;
  Upcoming(this.title, this.source, this.at, [this.notifId]);
}

// ===== core/theme.dart =====
class C {
  static const bg = Color(0xFF070B10);
  static const surface = Color(0xFF0F151D);
  static const surface2 = Color(0xFF151D28);
  static const line = Color(0xFF1F2A38);
  static const cyan = Color(0xFF00E5FF);
  static const red = Color(0xFFFF3B4E);
  static const green = Color(0xFF39FF9A);
  static const amber = Color(0xFFFFC53D);
  static const violet = Color(0xFFA78BFA);
  static const text = Color(0xFFE6EDF5);
  static const dim = Color(0xFF7E8DA0);
}

const String kMono = 'monospace';

ThemeData buildTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary: C.cyan,
      onPrimary: Colors.black,
      secondary: C.red,
      surface: C.surface,
      onSurface: C.text,
      error: C.red,
    ),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
  );
}

// ===== core/repository.dart =====
/// Storage abstraction. Each "space" ('normal', later 'secret') is stored separately.
///
/// Today: [LocalRepository] (on-device storage).
/// Later: add a `FirebaseRepository implements DataRepository` that reads/writes
/// Firestore / Storage under users/{uid}/spaces/{space}. Nothing else in the app
/// needs to change - AppState only talks to this interface.
abstract class DataRepository {
  Future<Map<String, dynamic>?> load(String space);
  Future<void> save(String space, Map<String, dynamic> data);
}

class LocalRepository implements DataRepository {
  final SharedPreferences prefs;
  LocalRepository(this.prefs);

  @override
  Future<Map<String, dynamic>?> load(String space) async {
    final raw = prefs.getString('data_$space');
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String space, Map<String, dynamic> data) async {
    await prefs.setString('data_$space', jsonEncode(data));
  }
}

// ===== core/auth.dart =====
enum AuthResult { normal, secret, denied }

/// One password box on the lock screen. The entered password decides the space:
///  - matches the normal password  -> normal space
///  - matches the (future) secret password -> secret space
/// The UI never says which is which.
class AuthService {
  final SharedPreferences prefs;
  AuthService(this.prefs);

  static const _kNormal = 'auth_normal';
  static const _kSecret = 'auth_secret';
  static const _kSalt = 'auth_salt';

  bool get hasNormal => prefs.getString(_kNormal) != null;
  bool get hasSecret => prefs.getString(_kSecret) != null;
  bool get hasLock => hasNormal;

  String _salt() {
    var s = prefs.getString(_kSalt);
    if (s == null) {
      final r = Random.secure();
      s = base64UrlEncode(List<int>.generate(16, (_) => r.nextInt(256)));
      prefs.setString(_kSalt, s);
    }
    return s;
  }

  String _hash(String pwd) => sha256.convert(utf8.encode('${_salt()}::$pwd')).toString();

  Future<void> setNormal(String pwd) async => prefs.setString(_kNormal, _hash(pwd));
  Future<void> removeNormal() async => prefs.remove(_kNormal);

  /// Ready for the secret system (not exposed in the UI yet).
  Future<bool> setSecret(String pwd) async {
    if (hasNormal && prefs.getString(_kNormal) == _hash(pwd)) return false;
    await prefs.setString(_kSecret, _hash(pwd));
    return true;
  }

  AuthResult verify(String pwd) {
    final h = _hash(pwd);
    if (hasSecret && prefs.getString(_kSecret) == h) return AuthResult.secret;
    if (hasNormal && prefs.getString(_kNormal) == h) return AuthResult.normal;
    return AuthResult.denied;
  }

  bool verifyNormal(String pwd) => hasNormal && prefs.getString(_kNormal) == _hash(pwd);
}

// ===== core/notification_service.dart =====
/// Schedules local notifications. Each item owns a "series" of ids:
/// id = base * 64 + index, so a repeating reminder is just many one-off alarms
/// that get refreshed every time the app opens.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static const int _slots = 64;

  Future<void> init() async {
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> requestPermission() async {
    try {
      return (await _android?.requestNotificationsPermission()) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestExactAlarms() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  Future<AndroidScheduleMode> _mode() async {
    try {
      final can = await _android?.canScheduleExactNotifications();
      if (can == true) return AndroidScheduleMode.exactAllowWhileIdle;
    } catch (_) {}
    return AndroidScheduleMode.inexactAllowWhileIdle;
  }

  NotificationDetails _details(String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          'agent_alerts',
          'Mission Alerts',
          channelDescription: 'Reminders and alerts from AGENT.OS',
          importance: Importance.max,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  Future<void> showNow(String title, String body) async {
    try {
      await _plugin.show(0, title, body, _details(body));
    } catch (_) {}
  }

  Future<void> scheduleSeries({
    required int base,
    required List<DateTime> times,
    required String title,
    required String body,
    bool clear = true,
  }) async {
    if (clear) await cancelSeries(base);
    final mode = await _mode();
    final now = DateTime.now();
    for (var i = 0; i < times.length && i < kMaxSeries; i++) {
      if (!times[i].isAfter(now)) continue;
      try {
        await _plugin.zonedSchedule(
          base * _slots + i,
          title,
          body,
          tz.TZDateTime.from(times[i], tz.UTC),
          _details(body),
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      } catch (_) {}
    }
  }

  Future<void> cancelSeries(int base) async {
    try {
      final pending = await _plugin.pendingNotificationRequests();
      for (final p in pending) {
        if (p.id ~/ _slots == base) await _plugin.cancel(p.id);
      }
    } catch (_) {}
  }

  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }
}

// ===== core/app_state.dart =====
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  late SharedPreferences prefs;
  late AuthService auth;
  late DataRepository repo;

  String space = 'normal';
  bool loaded = false;

  List<Task> tasks = [];
  List<NotifItem> notifs = [];
  List<Habit> habits = [];
  List<StudySession> sessions = [];
  List<Expense> expenses = [];
  List<Exam> exams = [];

  Timer? _ticker;
  final _notif = NotificationService.instance;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    auth = AuthService(prefs);
    repo = LocalRepository(prefs);
  }

  bool get autoLock => prefs.getBool('auto_lock') ?? true;
  Future<void> setAutoLock(bool v) async {
    await prefs.setBool('auto_lock', v);
    notifyListeners();
  }

  void refreshUi() => notifyListeners();

  int nextId() {
    final v = (prefs.getInt('id_counter') ?? 1000) + 1;
    prefs.setInt('id_counter', v);
    return v;
  }

  // ---------- space lifecycle ----------

  List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
      ((v as List?) ?? []).map((e) => f(Map<String, dynamic>.from(e as Map))).toList();

  Future<void> openSpace(String s) async {
    space = s;
    final m = await repo.load(s) ?? <String, dynamic>{};
    tasks = _list(m['tasks'], Task.fromJson);
    notifs = _list(m['notifs'], NotifItem.fromJson);
    habits = _list(m['habits'], Habit.fromJson);
    sessions = _list(m['sessions'], StudySession.fromJson);
    expenses = _list(m['expenses'], Expense.fromJson);
    exams = _list(m['exams'], Exam.fromJson);
    loaded = true;
    await _sync();
    await _commit(notify: false);
    await rescheduleAll();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) => refreshHistory());
    notifyListeners();
  }

  void closeSpace() {
    _ticker?.cancel();
    loaded = false;
    tasks = [];
    notifs = [];
    habits = [];
    sessions = [];
    expenses = [];
    exams = [];
    notifyListeners();
  }

  Future<void> _commit({bool notify = true}) async {
    if (!loaded) return;
    await repo.save(space, {
      'tasks': tasks.map((e) => e.toJson()).toList(),
      'notifs': notifs.map((e) => e.toJson()).toList(),
      'habits': habits.map((e) => e.toJson()).toList(),
      'sessions': sessions.map((e) => e.toJson()).toList(),
      'expenses': expenses.map((e) => e.toJson()).toList(),
      'exams': exams.map((e) => e.toJson()).toList(),
    });
    if (notify) notifyListeners();
  }

  // ---------- history sync ----------

  Future<bool> _sync() async {
    final now = DateTime.now();
    var changed = false;
    for (final n in notifs) {
      if (n.status == 'pending' && !n.at.isAfter(now)) {
        n.status = 'delivered';
        changed = true;
      }
    }
    for (final t in tasks) {
      if (t.status != 'active') continue;
      final el = t.elapsed(now);
      if (el.isEmpty) continue;
      for (final at in el) {
        notifs.add(NotifItem(
          id: nextId(),
          title: t.title,
          body: t.note,
          at: at,
          source: 'task',
          status: 'delivered',
        ));
      }
      t.loggedUntil = el.last;
      changed = true;
    }
    if (changed) {
      notifs.sort((a, b) => b.at.compareTo(a.at));
      if (notifs.length > 400) notifs = notifs.sublist(0, 400);
    }
    return changed;
  }

  Future<void> refreshHistory() async {
    if (!loaded) return;
    if (await _sync()) await _commit();
  }

  /// Called when the app comes back to the foreground.
  Future<void> refresh() async {
    if (!loaded) return;
    await _sync();
    await _commit();
    await rescheduleAll();
  }

  // ---------- scheduling ----------

  Future<void> _scheduleTask(Task t, {bool clear = true}) => _notif.scheduleSeries(
        base: t.id,
        times: t.occurrences(),
        title: '⚡ ${t.title}',
        body: t.note.isEmpty ? 'Mission reminder - mark it complete when done.' : t.note,
        clear: clear,
      );

  Future<void> _scheduleNotif(NotifItem n, {bool clear = true}) => _notif.scheduleSeries(
        base: n.id,
        times: [n.at],
        title: '🔔 ${n.title}',
        body: n.body.isEmpty ? 'Scheduled alert' : n.body,
        clear: clear,
      );

  List<DateTime> habitTimes(Habit h, {int days = 30}) {
    if (h.remindMin == null) return [];
    final now = DateTime.now();
    final out = <DateTime>[];
    for (var i = 0; i < days; i++) {
      final d = DateTime(now.year, now.month, now.day + i, h.remindMin! ~/ 60, h.remindMin! % 60);
      if (!d.isAfter(now)) continue;
      if (i == 0 && h.done.contains(dayKey(now))) continue;
      out.add(d);
    }
    return out;
  }

  List<DateTime> examTimes(Exam e) =>
      [e.at.subtract(const Duration(days: 1)), e.at.subtract(const Duration(hours: 1))];

  Future<void> _scheduleHabit(Habit h, {bool clear = true}) => _notif.scheduleSeries(
        base: h.id,
        times: habitTimes(h),
        title: '${h.emoji} ${h.name}',
        body: 'Daily habit check-in. Keep the streak alive.',
        clear: clear,
      );

  Future<void> _scheduleExam(Exam e, {bool clear = true}) => _notif.scheduleSeries(
        base: e.id,
        times: examTimes(e),
        title: '🎓 Exam: ${e.subject}',
        body: 'Exam is coming up on ${DateFormat('d MMM, h:mm a').format(e.at)}. Stay sharp.',
        clear: clear,
      );

  Future<void> rescheduleAll() async {
    await _notif.cancelAll();
    for (final t in tasks.where((t) => t.status == 'active')) {
      await _scheduleTask(t, clear: false);
    }
    for (final n in notifs.where((n) => n.status == 'pending')) {
      await _scheduleNotif(n, clear: false);
    }
    for (final h in habits) {
      await _scheduleHabit(h, clear: false);
    }
    for (final e in exams) {
      await _scheduleExam(e, clear: false);
    }
  }

  // ---------- tasks ----------

  Future<void> addTask({
    required String title,
    String note = '',
    required DateTime due,
    int repeatMin = 0,
    int priority = 1,
  }) async {
    final t = Task(id: nextId(), title: title, note: note, due: due, repeatMin: repeatMin, priority: priority);
    tasks.insert(0, t);
    await _commit();
    await _scheduleTask(t);
  }

  Future<void> completeTask(Task t) async {
    t.status = 'done';
    t.completedAt = DateTime.now();
    await _notif.cancelSeries(t.id);
    await _commit();
  }

  Future<void> deleteTask(Task t) async {
    t.status = 'deleted';
    t.completedAt = DateTime.now();
    await _notif.cancelSeries(t.id);
    await _commit();
  }

  Future<void> purgeTask(Task t) async {
    tasks.remove(t);
    await _commit();
  }

  Future<void> clearTaskHistory() async {
    tasks.removeWhere((t) => t.status != 'active');
    await _commit();
  }

  // ---------- alerts ----------

  Future<void> addNotif(String title, String body, DateTime at) async {
    final n = NotifItem(id: nextId(), title: title, body: body, at: at);
    notifs.insert(0, n);
    await _commit();
    await _scheduleNotif(n);
  }

  Future<void> cancelNotif(int id) async {
    for (final n in notifs) {
      if (n.id == id) n.status = 'cancelled';
    }
    await _notif.cancelSeries(id);
    await _commit();
  }

  Future<void> removeNotif(NotifItem n) async {
    notifs.remove(n);
    await _commit();
  }

  Future<void> clearNotifHistory() async {
    notifs.removeWhere((n) => n.status != 'pending');
    await _commit();
  }

  List<Upcoming> upcoming() {
    final now = DateTime.now();
    final out = <Upcoming>[];
    for (final n in notifs) {
      if (n.status == 'pending' && n.at.isAfter(now)) out.add(Upcoming(n.title, 'custom', n.at, n.id));
    }
    for (final t in tasks.where((t) => t.status == 'active')) {
      final o = t.occurrences(max: 1);
      if (o.isNotEmpty) out.add(Upcoming(t.title, 'task', o.first));
    }
    for (final h in habits) {
      final o = habitTimes(h, days: 2);
      if (o.isNotEmpty) out.add(Upcoming('${h.emoji} ${h.name}', 'habit', o.first));
    }
    for (final e in exams) {
      for (final tm in examTimes(e)) {
        if (tm.isAfter(now)) {
          out.add(Upcoming('Exam: ${e.subject}', 'exam', tm));
          break;
        }
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  // ---------- habits ----------

  Future<void> addHabit(String name, String emoji, int? remindMin) async {
    final h = Habit(id: nextId(), name: name, emoji: emoji, remindMin: remindMin);
    habits.add(h);
    await _commit();
    await _scheduleHabit(h);
  }

  Future<void> toggleHabit(Habit h, DateTime day) async {
    final k = dayKey(day);
    if (!h.done.remove(k)) h.done.add(k);
    await _commit();
    await _scheduleHabit(h);
  }

  Future<void> deleteHabit(Habit h) async {
    habits.remove(h);
    await _notif.cancelSeries(h.id);
    await _commit();
  }

  // ---------- study ----------

  Future<void> addSession(String subject, int minutes) async {
    sessions.insert(0, StudySession(subject: subject, minutes: minutes, at: DateTime.now()));
    await _commit();
  }

  // ---------- expenses ----------

  Future<void> addExpense(double amount, String category, String note) async {
    expenses.insert(0, Expense(id: nextId(), amount: amount, category: category, note: note, at: DateTime.now()));
    await _commit();
  }

  Future<void> deleteExpense(Expense e) async {
    expenses.remove(e);
    await _commit();
  }

  // ---------- exams ----------

  Future<void> addExam(String subject, DateTime at) async {
    final e = Exam(id: nextId(), subject: subject, at: at);
    exams.add(e);
    exams.sort((a, b) => a.at.compareTo(b.at));
    await _commit();
    await _scheduleExam(e);
  }

  Future<void> deleteExam(Exam e) async {
    exams.remove(e);
    await _notif.cancelSeries(e.id);
    await _commit();
  }

  // ---------- stats for charts ----------

  DateTime _day(int back) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day - back);
  }

  List<String> dayLabels(int n) =>
      List.generate(n, (i) => DateFormat('E').format(_day(n - 1 - i)).substring(0, 1));

  List<double> completedPerDay(int n) => List.generate(n, (i) {
        final k = dayKey(_day(n - 1 - i));
        return tasks
            .where((t) => t.status == 'done' && t.completedAt != null && dayKey(t.completedAt!) == k)
            .length
            .toDouble();
      });

  List<double> studyPerDay(int n) => List.generate(n, (i) {
        final k = dayKey(_day(n - 1 - i));
        return sessions.where((s) => dayKey(s.at) == k).fold<int>(0, (a, s) => a + s.minutes).toDouble();
      });

  int get studyToday => studyPerDay(1).first.toInt();
  int get doneToday => completedPerDay(1).first.toInt();
  int get pendingCount => tasks.where((t) => t.status == 'active').length;
  int get bestStreak => habits.fold<int>(0, (a, h) => h.streak > a ? h.streak : a);
  int get habitsDoneToday => habits.where((h) => h.done.contains(dayKey(DateTime.now()))).length;

  double get monthSpend {
    final n = DateTime.now();
    return expenses.where((e) => e.at.year == n.year && e.at.month == n.month).fold<double>(0, (a, e) => a + e.amount);
  }

  Map<String, double> get monthByCategory {
    final n = DateTime.now();
    final m = <String, double>{};
    for (final e in expenses.where((e) => e.at.year == n.year && e.at.month == n.month)) {
      m[e.category] = (m[e.category] ?? 0) + e.amount;
    }
    return m;
  }
}

// ===== ui/widgets.dart =====
TextStyle ts(double size, {FontWeight w = FontWeight.w500, Color c = C.text, bool m = false, double ls = 0}) =>
    TextStyle(fontSize: size, fontWeight: w, color: c, letterSpacing: ls, fontFamily: m ? kMono : null);

InputDecoration deco(String label, {String? hint, IconData? icon}) {
  OutlineInputBorder b(Color c) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c));
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon, size: 20, color: C.dim),
    filled: true,
    fillColor: C.surface2,
    labelStyle: ts(13, c: C.dim),
    hintStyle: ts(13, c: C.dim),
    border: b(C.line),
    enabledBorder: b(C.line),
    focusedBorder: b(C.cyan),
  );
}

String fmtDT(DateTime d) => DateFormat('EEE, d MMM • h:mm a').format(d);
String fmtTimeOfDay(int minutes) =>
    DateFormat('h:mm a').format(DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60));

String repeatLabel(int m) {
  if (m <= 0) return 'Once';
  if (m == 1440) return 'Daily';
  if (m < 60) return 'Every $m min';
  if (m % 60 == 0) return 'Every ${m ~/ 60} hr';
  return 'Every $m min';
}

String countdown(DateTime at) {
  final d = at.difference(DateTime.now());
  if (d.isNegative) return 'now';
  if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m';
}

class HudCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Color accent;
  final VoidCallback? onTap;
  const HudCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.accent = C.cyan,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(16);
    return Padding(
      padding: margin,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [C.surface2, C.surface],
            ),
            borderRadius: r,
            border: Border.all(color: accent.withOpacity(0.28)),
          ),
          child: InkWell(
            borderRadius: r,
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
        child: Row(children: [
          Container(width: 3, height: 14, color: C.cyan),
          const SizedBox(width: 8),
          Text(title.toUpperCase(), style: ts(12, c: C.dim, m: true, ls: 2, w: FontWeight.w700)),
          const Spacer(),
          if (trailing != null) trailing!,
        ]),
      );
}

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const StatTile({super.key, required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => HudCard(
        accent: color,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 10),
          Text(value, style: ts(26, w: FontWeight.w800, c: color, m: true)),
          const SizedBox(height: 2),
          Text(label.toUpperCase(), style: ts(10.5, c: C.dim, m: true, ls: 1.2)),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyState(this.icon, this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: C.line),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: ts(13, c: C.dim, m: true)),
          ]),
        ),
      );
}

class NeonButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color color;
  const NeonButton(this.label, {super.key, this.icon, this.onTap, this.color = C.cyan});

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.black,
          disabledBackgroundColor: C.line,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
          Text(label, style: ts(14, w: FontWeight.w800, c: Colors.black, m: true, ls: 1.5)),
        ]),
      );
}

class ChipRow<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  final Color color;
  const ChipRow({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onChanged,
    this.color = C.cyan,
  });

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            ChoiceChip(
              label: Text(label(v), style: ts(12.5, c: v == selected ? color : C.dim, w: FontWeight.w700)),
              selected: v == selected,
              showCheckmark: false,
              selectedColor: color.withOpacity(0.18),
              backgroundColor: C.surface2,
              side: BorderSide(color: v == selected ? color : C.line),
              onSelected: (_) => onChanged(v),
            ),
        ],
      );
}

Future<T?> showSheet<T>(BuildContext context, Widget Function(BuildContext) builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: C.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          builder(ctx),
        ]),
      ),
    ),
  );
}

Future<DateTime?> pickDateTime(BuildContext context, DateTime initial) async {
  final d = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2020),
    lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
  );
  if (d == null) return null;
  if (!context.mounted) return null;
  final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg, style: ts(13, m: true)),
      backgroundColor: C.surface2,
      behavior: SnackBarBehavior.floating,
    ));
}

/// Tappable date/time field used in forms.
class DateTimeField extends StatelessWidget {
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  const DateTimeField({super.key, required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final r = await pickDateTime(context, value);
          if (r != null) onChanged(r);
        },
        child: InputDecorator(
          decoration: deco(label, icon: Icons.event),
          child: Text(fmtDT(value), style: ts(14, m: true)),
        ),
      );
}

// ===== ui/charts.dart =====
FlTitlesData _titles(List<String> labels) {
  final none = AxisTitles(sideTitles: SideTitles(showTitles: false));
  return FlTitlesData(
    leftTitles: none,
    rightTitles: none,
    topTitles: none,
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 26,
        interval: 1,
        getTitlesWidget: (v, meta) {
          final i = v.toInt();
          if (i < 0 || i >= labels.length) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(labels[i], style: ts(11, c: C.dim, m: true)),
          );
        },
      ),
    ),
  );
}

double _maxY(List<double> v, double minTop) {
  final m = v.isEmpty ? 0.0 : v.reduce(max);
  return max(minTop, m * 1.25);
}

class MiniBar extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;
  const MiniBar({super.key, required this.values, required this.labels, this.color = C.cyan, this.height = 150});

  @override
  Widget build(BuildContext context) {
    final top = _maxY(values, 4);
    return SizedBox(
      height: height,
      child: BarChart(BarChartData(
        maxY: top,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: top / 4,
          getDrawingHorizontalLine: (v) => FlLine(color: C.line, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: _titles(labels),
        barGroups: [
          for (var i = 0; i < values.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: values[i],
                width: 14,
                color: color,
                borderRadius: BorderRadius.circular(4),
                backDrawRodData: BackgroundBarChartRodData(show: true, toY: top, color: C.line.withOpacity(0.4)),
              ),
            ]),
        ],
      )),
    );
  }
}

class MiniLine extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;
  const MiniLine({super.key, required this.values, required this.labels, this.color = C.violet, this.height = 150});

  @override
  Widget build(BuildContext context) {
    final top = _maxY(values, 30);
    return SizedBox(
      height: height,
      child: LineChart(LineChartData(
        minY: 0,
        maxY: top,
        minX: 0,
        maxX: (values.length - 1).toDouble(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: top / 4,
          getDrawingHorizontalLine: (v) => FlLine(color: C.line, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: _titles(labels),
        lineBarsData: [
          LineChartBarData(
            spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
            isCurved: true,
            color: color,
            barWidth: 3,
            dotData: FlDotData(show: true),
            belowBarData: BarAreaData(show: true, color: color.withOpacity(0.15)),
          ),
        ],
      )),
    );
  }
}

class Donut extends StatelessWidget {
  final List<double> values;
  final List<Color> colors;
  final Widget center;
  final double size;
  const Donut({super.key, required this.values, required this.colors, required this.center, this.size = 150});

  @override
  Widget build(BuildContext context) {
    final total = values.fold<double>(0, (a, b) => a + b);
    final sections = total <= 0
        ? [PieChartSectionData(value: 1, color: C.line, title: '', radius: 16)]
        : [
            for (var i = 0; i < values.length; i++)
              if (values[i] > 0) PieChartSectionData(value: values[i], color: colors[i], title: '', radius: 16),
          ];
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        PieChart(PieChartData(sections: sections, centerSpaceRadius: size / 2 - 18, sectionsSpace: 2)),
        center,
      ]),
    );
  }
}

// ===== pages/secret_home.dart =====
/// Placeholder for the future secret system (built after exams).
/// The auth flow, separate storage space and routing are already wired:
/// entering the secret password lands here instead of the normal Shell.
class SecretHome extends StatelessWidget {
  final VoidCallback onLock;
  const SecretHome({super.key, required this.onLock});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.shield, size: 64, color: C.red),
              const SizedBox(height: 16),
              Text('SECTOR 7', style: ts(26, m: true, c: C.red, w: FontWeight.w800, ls: 4)),
              const SizedBox(height: 8),
              Text('Secure vault - under construction', style: ts(13, c: C.dim, m: true)),
              const SizedBox(height: 32),
              NeonButton('LOCK', icon: Icons.lock, onTap: onLock, color: C.red),
            ]),
          ),
        ),
      );
}

// ===== pages/lock_screen.dart =====
class LockScreen extends StatefulWidget {
  final Future<void> Function(AuthResult) onResult;
  const LockScreen({super.key, required this.onResult});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _scan =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  final _ctrl = TextEditingController();
  int _fails = 0;
  DateTime? _lockedUntil;
  Timer? _timer;
  bool _denied = false;
  bool _hide = true;

  @override
  void dispose() {
    _scan.dispose();
    _ctrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  int get _wait => _lockedUntil == null ? 0 : max(0, _lockedUntil!.difference(DateTime.now()).inSeconds + 1);

  void _submit() {
    if (_wait > 0) return;
    final r = AppState.instance.auth.verify(_ctrl.text);
    if (r == AuthResult.denied) {
      _fails++;
      _denied = true;
      _ctrl.clear();
      if (_fails % 5 == 0) {
        _lockedUntil = DateTime.now().add(Duration(seconds: 30 * (_fails ~/ 5)));
        _timer?.cancel();
        _timer = Timer.periodic(const Duration(seconds: 1), (t) {
          if (_wait <= 0) t.cancel();
          if (mounted) setState(() {});
        });
      }
      setState(() {});
    } else {
      _denied = false;
      widget.onResult(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _wait > 0;
    Widget field = TextField(
      controller: _ctrl,
      obscureText: _hide,
      enabled: !locked,
      autocorrect: false,
      enableSuggestions: false,
      textAlign: TextAlign.center,
      style: ts(18, m: true, ls: 3),
      onSubmitted: (_) => _submit(),
      decoration: deco('Enter password').copyWith(
        suffixIcon: IconButton(
          icon: Icon(_hide ? Icons.visibility_off : Icons.visibility, color: C.dim, size: 20),
          onPressed: () => setState(() => _hide = !_hide),
        ),
      ),
    );
    if (_fails > 0) {
      field = TweenAnimationBuilder<double>(
        key: ValueKey(_fails),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 450),
        builder: (c, v, child) => Transform.translate(offset: Offset(sin(v * pi * 6) * 12 * (1 - v), 0), child: child),
        child: field,
      );
    }

    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _scan,
            builder: (c, _) => CustomPaint(painter: _HudPainter(_scan.value, _denied ? C.red : C.cyan)),
          ),
        ),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: (_denied ? C.red : C.cyan).withOpacity(0.6), width: 2),
                    boxShadow: [BoxShadow(color: (_denied ? C.red : C.cyan).withOpacity(0.35), blurRadius: 30)],
                  ),
                  child: Icon(_denied ? Icons.gpp_bad : Icons.fingerprint, size: 56, color: _denied ? C.red : C.cyan),
                ),
                const SizedBox(height: 28),
                Text('AGENT.OS', style: ts(30, m: true, w: FontWeight.w800, ls: 6)),
                const SizedBox(height: 6),
                Text('IDENTITY VERIFICATION', style: ts(12, m: true, c: C.dim, ls: 3)),
                const SizedBox(height: 36),
                field,
                const SizedBox(height: 14),
                SizedBox(
                  height: 20,
                  child: Text(
                    locked
                        ? 'LOCKDOWN - RETRY IN ${_wait}s'
                        : _denied
                            ? 'ACCESS DENIED'
                            : '',
                    style: ts(12, m: true, c: C.red, ls: 2, w: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 10),
                NeonButton('AUTHENTICATE', icon: Icons.lock_open, onTap: locked ? null : _submit),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _HudPainter extends CustomPainter {
  final double t;
  final Color color;
  _HudPainter(this.t, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = color.withOpacity(0.06)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final y = size.height * t;
    final rect = Rect.fromLTWH(0, y - 60, size.width, 120);
    final scan = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withOpacity(0), color.withOpacity(0.14), color.withOpacity(0)],
      ).createShader(rect);
    canvas.drawRect(rect, scan);
    final corner = Paint()
      ..color = color.withOpacity(0.7)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const m = 18.0, l = 26.0;
    canvas.drawPath(
        Path()
          ..moveTo(m, m + l)
          ..lineTo(m, m)
          ..lineTo(m + l, m),
        corner);
    canvas.drawPath(
        Path()
          ..moveTo(size.width - m - l, m)
          ..lineTo(size.width - m, m)
          ..lineTo(size.width - m, m + l),
        corner);
    canvas.drawPath(
        Path()
          ..moveTo(m, size.height - m - l)
          ..lineTo(m, size.height - m)
          ..lineTo(m + l, size.height - m),
        corner);
    canvas.drawPath(
        Path()
          ..moveTo(size.width - m - l, size.height - m)
          ..lineTo(size.width - m, size.height - m)
          ..lineTo(size.width - m, size.height - m - l),
        corner);
  }

  @override
  bool shouldRepaint(_HudPainter old) => old.t != t || old.color != color;
}

// ===== pages/root_gate.dart =====
/// Decides what to show: lock screen -> normal space or (later) secret space.
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> with WidgetsBindingObserver {
  AuthResult? _session;
  bool _booting = true;
  DateTime? _pausedAt;
  final _app = AppState.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _boot() async {
    if (!_app.auth.hasLock) {
      await _app.openSpace('normal');
      _session = AuthResult.normal;
    }
    if (mounted) setState(() => _booting = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _session != null) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (_app.auth.hasLock && _app.autoLock && away.inSeconds > 15) {
        _lock();
      } else {
        _app.refresh();
      }
    }
  }

  void _lock() {
    _app.closeSpace();
    if (mounted) setState(() => _session = null);
  }

  Future<void> _unlocked(AuthResult r) async {
    await _app.openSpace(r == AuthResult.secret ? 'secret' : 'normal');
    if (mounted) setState(() => _session = r);
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return Scaffold(
        body: Center(child: Text('AGENT.OS', style: ts(22, m: true, c: C.cyan, ls: 4, w: FontWeight.w800))),
      );
    }
    switch (_session) {
      case null:
      case AuthResult.denied:
        return LockScreen(onResult: _unlocked);
      case AuthResult.normal:
        return Shell(onLock: _lock);
      case AuthResult.secret:
        return SecretHome(onLock: _lock);
    }
  }
}

// ===== pages/shell.dart =====
/// Main navigation for the normal space.
class Shell extends StatefulWidget {
  final VoidCallback onLock;
  const Shell({super.key, required this.onLock});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const DashboardPage(),
      const TasksPage(),
      const AlertsPage(),
      const LabPage(),
      SettingsPage(onLock: widget.onLock),
    ];
    Widget dest(IconData icon, String label) => NavigationDestination(
          icon: Icon(icon, color: C.dim),
          selectedIcon: Icon(icon, color: C.cyan),
          label: label,
        );
    return Scaffold(
      body: IndexedStack(index: _i, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _i,
        onDestinationSelected: (v) => setState(() => _i = v),
        backgroundColor: C.surface,
        indicatorColor: C.cyan.withOpacity(0.15),
        height: 68,
        labelTextStyle: WidgetStateProperty.all(ts(10.5, m: true, c: C.dim, ls: 1)),
        destinations: [
          dest(Icons.dashboard_outlined, 'HQ'),
          dest(Icons.checklist, 'MISSIONS'),
          dest(Icons.notifications_active_outlined, 'ALERTS'),
          dest(Icons.science_outlined, 'LAB'),
          dest(Icons.settings_outlined, 'SETUP'),
        ],
      ),
    );
  }
}

// ===== pages/dashboard_page.dart =====
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  String _greet() {
    final h = DateTime.now().hour;
    if (h < 12) return 'GOOD MORNING';
    if (h < 17) return 'GOOD AFTERNOON';
    return 'GOOD EVENING';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppState.instance,
      builder: (context, _) {
        final s = AppState.instance;
        final up = s.upcoming().take(3).toList();
        final habitTotal = s.habits.length;
        final habitDone = s.habitsDoneToday;
        final nextExam = s.exams.where((e) => e.at.isAfter(DateTime.now())).toList();
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${_greet()}, AGENT', style: ts(20, m: true, w: FontWeight.w800, ls: 1.5)),
                    const SizedBox(height: 4),
                    Text(DateFormat('EEEE, d MMMM').format(DateTime.now()).toUpperCase(),
                        style: ts(12, m: true, c: C.dim, ls: 1.5)),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: C.green.withOpacity(0.6)),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.circle, size: 8, color: C.green),
                    const SizedBox(width: 6),
                    Text('ONLINE', style: ts(10.5, m: true, c: C.green, ls: 1.5, w: FontWeight.w700)),
                  ]),
                ),
              ]),
              const SizedBox(height: 18),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.55,
                children: [
                  StatTile(label: 'Active missions', value: '${s.pendingCount}', icon: Icons.flag, color: C.cyan),
                  StatTile(label: 'Done today', value: '${s.doneToday}', icon: Icons.verified, color: C.green),
                  StatTile(label: 'Study today', value: '${s.studyToday}m', icon: Icons.menu_book, color: C.violet),
                  StatTile(label: 'Best streak', value: '${s.bestStreak}d', icon: Icons.local_fire_department, color: C.amber),
                ],
              ),
              const SectionHeader('Missions completed - 7 days'),
              HudCard(child: MiniBar(values: s.completedPerDay(7), labels: s.dayLabels(7), color: C.green)),
              const SectionHeader('Study minutes - 7 days'),
              HudCard(accent: C.violet, child: MiniLine(values: s.studyPerDay(7), labels: s.dayLabels(7))),
              const SectionHeader("Today's habits"),
              HudCard(
                accent: C.amber,
                child: Row(children: [
                  Donut(
                    size: 110,
                    values: [habitDone.toDouble(), (habitTotal - habitDone).toDouble()],
                    colors: const [C.amber, C.line],
                    center: Text(
                      habitTotal == 0 ? '-' : '${(habitDone * 100 / habitTotal).round()}%',
                      style: ts(20, m: true, w: FontWeight.w800, c: C.amber),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Text(
                      habitTotal == 0
                          ? 'No habits yet. Add some in LAB > Habits.'
                          : '$habitDone of $habitTotal habits completed today.',
                      style: ts(14, c: C.dim),
                    ),
                  ),
                ]),
              ),
              if (nextExam.isNotEmpty) ...[
                const SectionHeader('Next exam'),
                HudCard(
                  accent: C.red,
                  child: Row(children: [
                    const Icon(Icons.school, color: C.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(nextExam.first.subject, style: ts(16, w: FontWeight.w700)),
                        Text(fmtDT(nextExam.first.at), style: ts(12, c: C.dim, m: true)),
                      ]),
                    ),
                    Text(countdown(nextExam.first.at), style: ts(20, m: true, c: C.red, w: FontWeight.w800)),
                  ]),
                ),
              ],
              const SectionHeader('Next alerts'),
              if (up.isEmpty)
                const EmptyState(Icons.notifications_none, 'Nothing scheduled.\nCreate a mission or an alert.')
              else
                for (final u in up)
                  HudCard(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Icon(_srcIcon(u.source), color: C.cyan, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(u.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(14.5, w: FontWeight.w700)),
                          Text(fmtDT(u.at), style: ts(11.5, c: C.dim, m: true)),
                        ]),
                      ),
                      Text(countdown(u.at), style: ts(13, m: true, c: C.cyan, w: FontWeight.w700)),
                    ]),
                  ),
            ],
          ),
        );
      },
    );
  }
}

IconData _srcIcon(String s) {
  switch (s) {
    case 'task':
      return Icons.flag;
    case 'habit':
      return Icons.loop;
    case 'exam':
      return Icons.school;
    default:
      return Icons.notifications;
  }
}

// ===== pages/tasks_page.dart =====
Color _prio(int p) => p == 2 ? C.red : (p == 1 ? C.amber : C.green);

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: C.bg,
          title: Text('MISSIONS', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
          bottom: TabBar(
            indicatorColor: C.cyan,
            labelColor: C.cyan,
            unselectedLabelColor: C.dim,
            labelStyle: ts(12, m: true, ls: 2, w: FontWeight.w800),
            tabs: const [Tab(text: 'ACTIVE'), Tab(text: 'HISTORY')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: C.cyan,
          foregroundColor: Colors.black,
          icon: const Icon(Icons.add),
          label: Text('NEW MISSION', style: ts(12, m: true, c: Colors.black, w: FontWeight.w800, ls: 1)),
          onPressed: () => showSheet(context, (_) => const _TaskForm()),
        ),
        body: ListenableBuilder(
          listenable: AppState.instance,
          builder: (context, _) {
            final s = AppState.instance;
            final active = s.tasks.where((t) => t.status == 'active').toList()
              ..sort((a, b) => a.due.compareTo(b.due));
            final hist = s.tasks.where((t) => t.status != 'active').toList()
              ..sort((a, b) => (b.completedAt ?? b.created).compareTo(a.completedAt ?? a.created));
            return TabBarView(children: [
              active.isEmpty
                  ? const EmptyState(Icons.flag_outlined, 'No active missions.\nTap NEW MISSION to deploy one.')
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                      children: [for (final t in active) _ActiveTile(t)],
                    ),
              hist.isEmpty
                  ? const EmptyState(Icons.history, 'Mission history is empty.')
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => s.clearTaskHistory(),
                            icon: const Icon(Icons.delete_sweep, size: 18, color: C.dim),
                            label: Text('CLEAR ALL', style: ts(11, m: true, c: C.dim, ls: 1)),
                          ),
                        ),
                        for (final t in hist) _HistoryTile(t),
                      ],
                    ),
            ]);
          },
        ),
      ),
    );
  }
}

class _ActiveTile extends StatelessWidget {
  final Task t;
  const _ActiveTile(this.t);

  @override
  Widget build(BuildContext context) {
    final overdue = t.due.isBefore(DateTime.now());
    final color = _prio(t.priority);
    return HudCard(
      accent: color,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
      child: Row(children: [
        IconButton(
          icon: Icon(Icons.radio_button_unchecked, color: color, size: 28),
          onPressed: () {
            AppState.instance.completeTask(t);
            toast(context, 'Mission complete: ${t.title}');
          },
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, style: ts(15.5, w: FontWeight.w700)),
            if (t.note.isNotEmpty) Text(t.note, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(12.5, c: C.dim)),
            const SizedBox(height: 6),
            Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.schedule, size: 13, color: overdue ? C.red : C.dim),
                const SizedBox(width: 4),
                Text(fmtDT(t.due), style: ts(11.5, m: true, c: overdue ? C.red : C.dim)),
              ]),
              if (t.repeatMin > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: C.cyan.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(repeatLabel(t.repeatMin), style: ts(10.5, m: true, c: C.cyan, w: FontWeight.w700)),
                ),
            ]),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: C.dim, size: 20),
          onPressed: () => AppState.instance.deleteTask(t),
        ),
      ]),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final Task t;
  const _HistoryTile(this.t);

  @override
  Widget build(BuildContext context) {
    final done = t.status == 'done';
    return HudCard(
      accent: done ? C.green : C.red,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(children: [
        Icon(done ? Icons.check_circle : Icons.cancel, color: done ? C.green : C.red),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title,
                style: ts(14.5, w: FontWeight.w700, c: C.dim).copyWith(decoration: TextDecoration.lineThrough)),
            const SizedBox(height: 4),
            Text(
              '${done ? 'COMPLETED' : 'DELETED'} ${t.completedAt == null ? '' : fmtDT(t.completedAt!)}',
              style: ts(10.5, m: true, c: done ? C.green : C.red, ls: 0.5),
            ),
            Text('${repeatLabel(t.repeatMin)} • due ${fmtDT(t.due)}', style: ts(10.5, m: true, c: C.dim)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: C.dim, size: 20),
          onPressed: () => AppState.instance.purgeTask(t),
        ),
      ]),
    );
  }
}

class _TaskForm extends StatefulWidget {
  const _TaskForm();
  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  DateTime _due = DateTime.now().add(const Duration(minutes: 30));
  int _repeat = 0;
  int _priority = 1;

  static const _repeats = [0, 30, 60, 120, 360, 1440];

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('NEW MISSION', style: ts(16, m: true, w: FontWeight.w800, ls: 2)),
      const SizedBox(height: 16),
      TextField(controller: _title, style: ts(15), decoration: deco('Title', icon: Icons.flag)),
      const SizedBox(height: 12),
      TextField(controller: _note, style: ts(14), decoration: deco('Note (optional)', icon: Icons.notes)),
      const SizedBox(height: 12),
      DateTimeField(label: 'Remind me at', value: _due, onChanged: (d) => setState(() => _due = d)),
      const SizedBox(height: 16),
      Text('REMIND AGAIN', style: ts(11, m: true, c: C.dim, ls: 2)),
      const SizedBox(height: 8),
      ChipRow<int>(
        values: _repeats,
        selected: _repeat,
        label: (v) => v == 0 ? 'No repeat' : repeatLabel(v),
        onChanged: (v) => setState(() => _repeat = v),
      ),
      if (_repeat > 0)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Keeps reminding until you mark the mission complete.', style: ts(11.5, c: C.dim)),
        ),
      const SizedBox(height: 16),
      Text('PRIORITY', style: ts(11, m: true, c: C.dim, ls: 2)),
      const SizedBox(height: 8),
      ChipRow<int>(
        values: const [0, 1, 2],
        selected: _priority,
        color: _prio(_priority),
        label: (v) => const ['Low', 'Medium', 'High'][v],
        onChanged: (v) => setState(() => _priority = v),
      ),
      const SizedBox(height: 22),
      NeonButton('DEPLOY', icon: Icons.rocket_launch, onTap: () async {
        final title = _title.text.trim();
        if (title.isEmpty) {
          toast(context, 'Give the mission a title');
          return;
        }
        await AppState.instance.addTask(
          title: title,
          note: _note.text.trim(),
          due: _due,
          repeatMin: _repeat,
          priority: _priority,
        );
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

// ===== pages/alerts_page.dart =====
class AlertsPage extends StatelessWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: C.bg,
          title: Text('ALERTS', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
          bottom: TabBar(
            indicatorColor: C.cyan,
            labelColor: C.cyan,
            unselectedLabelColor: C.dim,
            labelStyle: ts(12, m: true, ls: 2, w: FontWeight.w800),
            tabs: const [Tab(text: 'UPCOMING'), Tab(text: 'HISTORY')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: C.cyan,
          foregroundColor: Colors.black,
          icon: const Icon(Icons.add_alert),
          label: Text('NEW ALERT', style: ts(12, m: true, c: Colors.black, w: FontWeight.w800, ls: 1)),
          onPressed: () => showSheet(context, (_) => const _AlertForm()),
        ),
        body: ListenableBuilder(
          listenable: AppState.instance,
          builder: (context, _) {
            final s = AppState.instance;
            final up = s.upcoming();
            final hist = s.notifs.where((n) => n.status != 'pending').toList()
              ..sort((a, b) => b.at.compareTo(a.at));
            return TabBarView(children: [
              up.isEmpty
                  ? const EmptyState(Icons.notifications_none, 'No upcoming alerts.\nTap NEW ALERT to schedule one.')
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                      children: [
                        for (final u in up)
                          HudCard(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                            child: Row(children: [
                              Icon(_srcIcon(u.source), color: C.cyan),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(u.title, style: ts(14.5, w: FontWeight.w700)),
                                  Text(fmtDT(u.at), style: ts(11.5, m: true, c: C.dim)),
                                ]),
                              ),
                              Text(countdown(u.at), style: ts(13, m: true, c: C.cyan, w: FontWeight.w700)),
                              if (u.notifId != null)
                                IconButton(
                                  icon: const Icon(Icons.close, color: C.dim, size: 20),
                                  onPressed: () => s.cancelNotif(u.notifId!),
                                )
                              else
                                const SizedBox(width: 12),
                            ]),
                          ),
                      ],
                    ),
              hist.isEmpty
                  ? const EmptyState(Icons.history, 'Notification history is empty.\nDelivered alerts show up here.')
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => s.clearNotifHistory(),
                            icon: const Icon(Icons.delete_sweep, size: 18, color: C.dim),
                            label: Text('CLEAR ALL', style: ts(11, m: true, c: C.dim, ls: 1)),
                          ),
                        ),
                        for (final n in hist) _HistTile(n),
                      ],
                    ),
            ]);
          },
        ),
      ),
    );
  }
}

class _HistTile extends StatelessWidget {
  final NotifItem n;
  const _HistTile(this.n);

  @override
  Widget build(BuildContext context) {
    final cancelled = n.status == 'cancelled';
    final color = cancelled ? C.red : C.green;
    return HudCard(
      accent: color,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
      child: Row(children: [
        Icon(cancelled ? Icons.notifications_off : _srcIcon(n.source), color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.title, style: ts(14.5, w: FontWeight.w700)),
            if (n.body.isNotEmpty) Text(n.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: C.dim)),
            const SizedBox(height: 3),
            Text(
              '${cancelled ? 'CANCELLED' : 'DELIVERED'} • ${fmtDT(n.at)}',
              style: ts(10.5, m: true, c: color),
            ),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: C.dim, size: 20),
          onPressed: () => AppState.instance.removeNotif(n),
        ),
      ]),
    );
  }
}

class _AlertForm extends StatefulWidget {
  const _AlertForm();
  @override
  State<_AlertForm> createState() => _AlertFormState();
}

class _AlertFormState extends State<_AlertForm> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  DateTime _at = DateTime.now().add(const Duration(minutes: 5));

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('NEW ALERT', style: ts(16, m: true, w: FontWeight.w800, ls: 2)),
      const SizedBox(height: 16),
      TextField(controller: _title, style: ts(15), decoration: deco('Title', icon: Icons.title)),
      const SizedBox(height: 12),
      TextField(controller: _body, style: ts(14), decoration: deco('Message (optional)', icon: Icons.notes)),
      const SizedBox(height: 12),
      DateTimeField(label: 'Date & time', value: _at, onChanged: (d) => setState(() => _at = d)),
      const SizedBox(height: 22),
      NeonButton('SCHEDULE', icon: Icons.alarm_add, onTap: () async {
        final title = _title.text.trim();
        if (title.isEmpty) {
          toast(context, 'Give the alert a title');
          return;
        }
        if (!_at.isAfter(DateTime.now())) {
          toast(context, 'Pick a time in the future');
          return;
        }
        await AppState.instance.addNotif(title, _body.text.trim(), _at);
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

// ===== pages/habits_page.dart =====
class HabitsPage extends StatelessWidget {
  const HabitsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('HABITS', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.amber,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: Text('NEW HABIT', style: ts(12, m: true, c: Colors.black, w: FontWeight.w800, ls: 1)),
        onPressed: () => showSheet(context, (_) => const _HabitForm()),
      ),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final hs = AppState.instance.habits;
          if (hs.isEmpty) return const EmptyState(Icons.loop, 'No habits yet.\nBuild streaks with daily check-ins.');
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
            children: [for (final h in hs) _HabitCard(h)],
          );
        },
      ),
    );
  }
}

class _HabitCard extends StatelessWidget {
  final Habit h;
  const _HabitCard(this.h);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = List.generate(7, (i) => DateTime(now.year, now.month, now.day - (6 - i)));
    const wk = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return HudCard(
      accent: C.amber,
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(h.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.name, style: ts(16, w: FontWeight.w800)),
              Text(
                h.remindMin == null ? 'No reminder' : 'Daily at ${fmtTimeOfDay(h.remindMin!)}',
                style: ts(11.5, m: true, c: C.dim),
              ),
            ]),
          ),
          Column(children: [
            Row(children: [
              const Icon(Icons.local_fire_department, color: C.amber, size: 20),
              Text('${h.streak}', style: ts(20, m: true, c: C.amber, w: FontWeight.w800)),
            ]),
            Text('STREAK', style: ts(9, m: true, c: C.dim, ls: 1)),
          ]),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: C.dim, size: 20),
            onPressed: () => AppState.instance.deleteHabit(h),
          ),
        ]),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (final d in days)
            GestureDetector(
              onTap: () => AppState.instance.toggleHabit(h, d),
              child: Column(children: [
                Text(wk[d.weekday - 1], style: ts(10.5, m: true, c: C.dim)),
                const SizedBox(height: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: h.done.contains(dayKey(d)) ? C.amber : Colors.transparent,
                    border: Border.all(
                      color: dayKey(d) == dayKey(now) ? C.amber : C.line,
                      width: dayKey(d) == dayKey(now) ? 2 : 1,
                    ),
                  ),
                  child: h.done.contains(dayKey(d))
                      ? const Icon(Icons.check, color: Colors.black, size: 20)
                      : Center(child: Text('${d.day}', style: ts(11, m: true, c: C.dim))),
                ),
              ]),
            ),
        ]),
      ]),
    );
  }
}

class _HabitForm extends StatefulWidget {
  const _HabitForm();
  @override
  State<_HabitForm> createState() => _HabitFormState();
}

class _HabitFormState extends State<_HabitForm> {
  final _name = TextEditingController();
  String _emoji = '🎯';
  TimeOfDay? _time;

  static const _emojis = ['🎯', '💧', '📚', '🏃', '🧘', '😴', '🍎', '✍️'];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('NEW HABIT', style: ts(16, m: true, w: FontWeight.w800, ls: 2)),
      const SizedBox(height: 16),
      TextField(controller: _name, style: ts(15), decoration: deco('Habit name', icon: Icons.loop)),
      const SizedBox(height: 14),
      ChipRow<String>(
        values: _emojis,
        selected: _emoji,
        color: C.amber,
        label: (v) => v,
        onChanged: (v) => setState(() => _emoji = v),
      ),
      const SizedBox(height: 14),
      InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final t = await showTimePicker(context: context, initialTime: _time ?? const TimeOfDay(hour: 20, minute: 0));
          if (t != null) setState(() => _time = t);
        },
        child: InputDecorator(
          decoration: deco('Daily reminder', icon: Icons.alarm).copyWith(
            suffixIcon: _time == null
                ? null
                : IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => setState(() => _time = null)),
          ),
          child: Text(_time == null ? 'Off' : _time!.format(context), style: ts(14, m: true)),
        ),
      ),
      const SizedBox(height: 22),
      NeonButton('ADD HABIT', icon: Icons.check, color: C.amber, onTap: () async {
        final name = _name.text.trim();
        if (name.isEmpty) {
          toast(context, 'Name the habit');
          return;
        }
        await AppState.instance.addHabit(name, _emoji, _time == null ? null : _time!.hour * 60 + _time!.minute);
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

// ===== pages/study_page.dart =====
/// Lives outside the page so the timer keeps running while you navigate.
class FocusTimer extends ChangeNotifier {
  FocusTimer._();
  static final FocusTimer instance = FocusTimer._();

  bool running = false;
  DateTime? startedAt;
  DateTime? endAt;
  String subject = 'General';
  int minutes = 25;
  Timer? _t;

  Duration get remaining {
    if (!running) return Duration(minutes: minutes);
    final d = endAt!.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  double get progress {
    if (!running) return 0;
    final total = Duration(minutes: minutes).inSeconds;
    return 1 - remaining.inSeconds / total;
  }

  void start(String s, int m) {
    subject = s.isEmpty ? 'General' : s;
    minutes = m;
    startedAt = DateTime.now();
    endAt = startedAt!.add(Duration(minutes: m));
    running = true;
    NotificationService.instance.scheduleSeries(
      base: 1,
      times: [endAt!],
      title: '⏱ Focus session complete',
      body: '$subject - $m min done. Take a break.',
    );
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (remaining.inSeconds <= 0) {
        _finish(true);
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void stop() => _finish(false);

  void _finish(bool complete) {
    if (!running) return;
    final mins = complete ? minutes : DateTime.now().difference(startedAt!).inMinutes;
    _t?.cancel();
    running = false;
    if (!complete) NotificationService.instance.cancelSeries(1);
    if (mins >= 1) AppState.instance.addSession(subject, mins);
    notifyListeners();
  }
}

class StudyPage extends StatefulWidget {
  const StudyPage({super.key});
  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  final _subject = TextEditingController(text: FocusTimer.instance.subject);
  int _min = FocusTimer.instance.minutes;

  @override
  void dispose() {
    _subject.dispose();
    super.dispose();
  }

  String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final f = FocusTimer.instance;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('FOCUS TIMER', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([f, AppState.instance]),
        builder: (context, _) {
          final s = AppState.instance;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Center(
              child: SizedBox(
                width: 220,
                height: 220,
                child: Stack(alignment: Alignment.center, children: [
                  SizedBox(
                    width: 220,
                    height: 220,
                    child: CircularProgressIndicator(
                      value: f.running ? f.progress : 0,
                      strokeWidth: 10,
                      backgroundColor: C.line,
                      color: C.violet,
                    ),
                  ),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_mmss(f.remaining), style: ts(46, m: true, w: FontWeight.w800)),
                    Text(f.running ? f.subject.toUpperCase() : 'READY', style: ts(11, m: true, c: C.violet, ls: 2)),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 24),
            if (!f.running) ...[
              TextField(controller: _subject, style: ts(15), decoration: deco('Subject', icon: Icons.menu_book)),
              const SizedBox(height: 14),
              ChipRow<int>(
                values: const [15, 25, 45, 60, 90],
                selected: _min,
                color: C.violet,
                label: (v) => '$v min',
                onChanged: (v) => setState(() => _min = v),
              ),
              const SizedBox(height: 18),
              NeonButton('START FOCUS', icon: Icons.play_arrow, color: C.violet, onTap: () => f.start(_subject.text.trim(), _min)),
            ] else
              NeonButton('ABORT & SAVE', icon: Icons.stop, color: C.red, onTap: f.stop),
            const SectionHeader('Minutes studied - 7 days'),
            HudCard(accent: C.violet, child: MiniBar(values: s.studyPerDay(7), labels: s.dayLabels(7), color: C.violet)),
            const SectionHeader('Recent sessions'),
            if (s.sessions.isEmpty)
              const EmptyState(Icons.timer_outlined, 'No sessions yet.')
            else
              for (final x in s.sessions.take(8))
                HudCard(
                  accent: C.violet,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    const Icon(Icons.check_circle, color: C.violet, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(x.subject, style: ts(14, w: FontWeight.w700))),
                    Text('${x.minutes} min', style: ts(13, m: true, c: C.violet, w: FontWeight.w800)),
                    const SizedBox(width: 10),
                    Text(fmtDT(x.at), style: ts(10.5, m: true, c: C.dim)),
                  ]),
                ),
          ]);
        },
      ),
    );
  }
}

// ===== pages/exam_page.dart =====
class ExamPage extends StatelessWidget {
  const ExamPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('EXAMS', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.red,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: Text('ADD EXAM', style: ts(12, m: true, c: Colors.black, w: FontWeight.w800, ls: 1)),
        onPressed: () => showSheet(context, (_) => const _ExamForm()),
      ),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final ex = AppState.instance.exams;
          if (ex.isEmpty) {
            return const EmptyState(Icons.school_outlined, 'No exams added.\nYou get reminders 1 day and 1 hour before.');
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 90), children: [
            for (final e in ex)
              Builder(builder: (context) {
                final left = e.at.difference(DateTime.now());
                final past = left.isNegative;
                final color = past ? C.dim : (left.inDays < 3 ? C.red : (left.inDays < 10 ? C.amber : C.green));
                return HudCard(
                  accent: color,
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Row(children: [
                    Column(children: [
                      Text(past ? '-' : '${left.inDays}', style: ts(34, m: true, c: color, w: FontWeight.w800)),
                      Text(past ? 'DONE' : 'DAYS', style: ts(10, m: true, c: C.dim, ls: 1.5)),
                    ]),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.subject, style: ts(16, w: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text(fmtDT(e.at), style: ts(11.5, m: true, c: C.dim)),
                        if (!past) Text('in ${countdown(e.at)}', style: ts(11.5, m: true, c: color)),
                      ]),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: C.dim),
                      onPressed: () => AppState.instance.deleteExam(e),
                    ),
                  ]),
                );
              }),
          ]);
        },
      ),
    );
  }
}

class _ExamForm extends StatefulWidget {
  const _ExamForm();
  @override
  State<_ExamForm> createState() => _ExamFormState();
}

class _ExamFormState extends State<_ExamForm> {
  final _subject = TextEditingController();
  DateTime _at = DateTime.now().add(const Duration(days: 7));

  @override
  void dispose() {
    _subject.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('NEW EXAM', style: ts(16, m: true, w: FontWeight.w800, ls: 2)),
      const SizedBox(height: 16),
      TextField(controller: _subject, style: ts(15), decoration: deco('Subject', icon: Icons.school)),
      const SizedBox(height: 12),
      DateTimeField(label: 'Exam date & time', value: _at, onChanged: (d) => setState(() => _at = d)),
      const SizedBox(height: 22),
      NeonButton('SAVE EXAM', icon: Icons.check, color: C.red, onTap: () async {
        final s = _subject.text.trim();
        if (s.isEmpty) {
          toast(context, 'Enter the subject');
          return;
        }
        await AppState.instance.addExam(s, _at);
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

// ===== pages/expense_page.dart =====
const _cats = ['Food', 'Travel', 'Study', 'Fun', 'Bills', 'Other'];
const _catColors = [C.amber, C.cyan, C.violet, C.red, C.green, C.dim];
Color _catColor(String c) {
  final i = _cats.indexOf(c);
  return i < 0 ? C.dim : _catColors[i];
}

class ExpensePage extends StatelessWidget {
  const ExpensePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('EXPENSES', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.green,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: Text('ADD', style: ts(12, m: true, c: Colors.black, w: FontWeight.w800, ls: 1)),
        onPressed: () => showSheet(context, (_) => const _ExpenseForm()),
      ),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final s = AppState.instance;
          final by = s.monthByCategory;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 90), children: [
            HudCard(
              accent: C.green,
              child: Row(children: [
                Donut(
                  size: 130,
                  values: [for (final c in _cats) by[c] ?? 0],
                  colors: _catColors,
                  center: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('THIS MONTH', style: ts(8.5, m: true, c: C.dim, ls: 1)),
                    Text('₹${s.monthSpend.toStringAsFixed(0)}', style: ts(18, m: true, w: FontWeight.w800, c: C.green)),
                  ]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(children: [
                    for (var i = 0; i < _cats.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Container(width: 9, height: 9, decoration: BoxDecoration(color: _catColors[i], shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_cats[i], style: ts(12, c: C.dim))),
                          Text('₹${(by[_cats[i]] ?? 0).toStringAsFixed(0)}', style: ts(12, m: true)),
                        ]),
                      ),
                  ]),
                ),
              ]),
            ),
            const SectionHeader('Recent'),
            if (s.expenses.isEmpty)
              const EmptyState(Icons.account_balance_wallet_outlined, 'No expenses logged.')
            else
              for (final e in s.expenses.take(40))
                HudCard(
                  accent: _catColor(e.category),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                  child: Row(children: [
                    Container(width: 4, height: 34, color: _catColor(e.category)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.note.isEmpty ? e.category : e.note, style: ts(14, w: FontWeight.w700)),
                        Text('${e.category} • ${fmtDT(e.at)}', style: ts(10.5, m: true, c: C.dim)),
                      ]),
                    ),
                    Text('₹${e.amount.toStringAsFixed(0)}', style: ts(15, m: true, w: FontWeight.w800)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: C.dim),
                      onPressed: () => s.deleteExpense(e),
                    ),
                  ]),
                ),
          ]);
        },
      ),
    );
  }
}

class _ExpenseForm extends StatefulWidget {
  const _ExpenseForm();
  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String _cat = 'Food';

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('NEW EXPENSE', style: ts(16, m: true, w: FontWeight.w800, ls: 2)),
      const SizedBox(height: 16),
      TextField(
        controller: _amount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: ts(18, m: true),
        decoration: deco('Amount (₹)', icon: Icons.currency_rupee),
      ),
      const SizedBox(height: 12),
      TextField(controller: _note, style: ts(14), decoration: deco('Note (optional)', icon: Icons.notes)),
      const SizedBox(height: 14),
      ChipRow<String>(
        values: _cats,
        selected: _cat,
        color: _catColor(_cat),
        label: (v) => v,
        onChanged: (v) => setState(() => _cat = v),
      ),
      const SizedBox(height: 22),
      NeonButton('SAVE', icon: Icons.check, color: C.green, onTap: () async {
        final a = double.tryParse(_amount.text.trim());
        if (a == null || a <= 0) {
          toast(context, 'Enter a valid amount');
          return;
        }
        await AppState.instance.addExpense(a, _cat, _note.text.trim());
        if (context.mounted) Navigator.pop(context);
      }),
    ]);
  }
}

// ===== pages/gpa_page.dart =====
class _Row {
  final TextEditingController name = TextEditingController();
  double credits = 3;
  double grade = 8;
}

/// Quick SGPA calculator (10-point scale). Not saved - just a handy tool.
class GpaPage extends StatefulWidget {
  const GpaPage({super.key});
  @override
  State<GpaPage> createState() => _GpaPageState();
}

class _GpaPageState extends State<GpaPage> {
  final List<_Row> _rows = [_Row(), _Row(), _Row()];

  static const _grades = <String, double>{'O': 10, 'A+': 9, 'A': 8, 'B+': 7, 'B': 6, 'C': 5, 'F': 0};

  @override
  void dispose() {
    for (final r in _rows) {
      r.name.dispose();
    }
    super.dispose();
  }

  double get _sgpa {
    final cr = _rows.fold<double>(0, (a, r) => a + r.credits);
    if (cr == 0) return 0;
    return _rows.fold<double>(0, (a, r) => a + r.credits * r.grade) / cr;
  }

  @override
  Widget build(BuildContext context) {
    final g = _sgpa;
    final color = g >= 8.5 ? C.green : (g >= 7 ? C.cyan : (g >= 5 ? C.amber : C.red));
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('GPA CALCULATOR', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: C.cyan,
        foregroundColor: Colors.black,
        onPressed: () => setState(() => _rows.add(_Row())),
        child: const Icon(Icons.add),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 90), children: [
        HudCard(
          accent: color,
          child: Column(children: [
            Text('SGPA', style: ts(12, m: true, c: C.dim, ls: 3)),
            const SizedBox(height: 6),
            Text(g.toStringAsFixed(2), style: ts(54, m: true, c: color, w: FontWeight.w800)),
            Text('${_rows.fold<double>(0, (a, r) => a + r.credits).toStringAsFixed(0)} credits',
                style: ts(12, m: true, c: C.dim)),
          ]),
        ),
        const SectionHeader('Subjects'),
        for (var i = 0; i < _rows.length; i++)
          HudCard(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _rows[i].name,
                  style: ts(14),
                  decoration: deco('Subject ${i + 1}'),
                ),
              ),
              const SizedBox(width: 8),
              _drop<double>(
                value: _rows[i].credits,
                items: const [1, 2, 3, 4, 5, 6],
                label: (v) => '${v.toInt()} cr',
                onChanged: (v) => setState(() => _rows[i].credits = v),
              ),
              const SizedBox(width: 6),
              _drop<double>(
                value: _rows[i].grade,
                items: _grades.values.toList(),
                label: (v) => _grades.entries.firstWhere((e) => e.value == v).key,
                onChanged: (v) => setState(() => _rows[i].grade = v),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: C.dim),
                onPressed: _rows.length > 1
                    ? () => setState(() {
                          _rows[i].name.dispose();
                          _rows.removeAt(i);
                        })
                    : null,
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _drop<T>({
    required T value,
    required List<T> items,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) =>
      DropdownButton<T>(
        value: value,
        dropdownColor: C.surface2,
        underline: const SizedBox.shrink(),
        style: ts(13, m: true, c: C.cyan, w: FontWeight.w700),
        items: [for (final v in items) DropdownMenuItem<T>(value: v, child: Text(label(v)))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
}

// ===== pages/lab_page.dart =====
class LabPage extends StatelessWidget {
  const LabPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <_Tool>[
      _Tool('Habits', 'Streaks & daily check-ins', Icons.loop, C.amber, const HabitsPage()),
      _Tool('Focus Timer', 'Study sessions & stats', Icons.timer, C.violet, const StudyPage()),
      _Tool('Exams', 'Countdown & reminders', Icons.school, C.red, const ExamPage()),
      _Tool('Expenses', 'Spending & charts', Icons.account_balance_wallet, C.green, const ExpensePage()),
      _Tool('GPA Calc', 'SGPA in seconds', Icons.calculate, C.cyan, const GpaPage()),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('LAB', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      body: GridView.count(
        crossAxisCount: 2,
        padding: const EdgeInsets.all(16),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.95,
        children: [
          for (final t in items)
            HudCard(
              accent: t.color,
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => t.page)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: t.color.withOpacity(0.14), borderRadius: BorderRadius.circular(12)),
                  child: Icon(t.icon, color: t.color, size: 26),
                ),
                const Spacer(),
                Text(t.title, style: ts(16, w: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(t.sub, style: ts(11.5, c: C.dim)),
              ]),
            ),
        ],
      ),
    );
  }
}

class _Tool {
  final String title, sub;
  final IconData icon;
  final Color color;
  final Widget page;
  _Tool(this.title, this.sub, this.icon, this.color, this.page);
}

// ===== pages/settings_page.dart =====
class SettingsPage extends StatelessWidget {
  final VoidCallback onLock;
  const SettingsPage({super.key, required this.onLock});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: C.bg,
        title: Text('SETUP', style: ts(18, m: true, w: FontWeight.w800, ls: 2)),
      ),
      body: ListenableBuilder(
        listenable: AppState.instance,
        builder: (context, _) {
          final s = AppState.instance;
          final hasLock = s.auth.hasLock;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            const SectionHeader('Security'),
            HudCard(
              child: Column(children: [
                _row(
                  icon: hasLock ? Icons.lock : Icons.lock_open,
                  color: hasLock ? C.green : C.dim,
                  title: 'App password',
                  sub: hasLock ? 'Enabled - asked every time you open the app' : 'Off - the app opens directly',
                  trailing: TextButton(
                    onPressed: () => showSheet(context, (_) => _PasswordForm(change: hasLock)),
                    child: Text(hasLock ? 'CHANGE' : 'SET', style: ts(12, m: true, c: C.cyan, w: FontWeight.w800)),
                  ),
                ),
                if (hasLock) ...[
                  const Divider(color: C.line, height: 20),
                  _row(
                    icon: Icons.timer_off,
                    color: C.amber,
                    title: 'Auto-lock',
                    sub: 'Lock after leaving the app for 15 sec',
                    trailing: Switch(value: s.autoLock, onChanged: (v) => s.setAutoLock(v)),
                  ),
                  const Divider(color: C.line, height: 20),
                  _row(
                    icon: Icons.lock_reset,
                    color: C.red,
                    title: 'Remove password',
                    sub: 'Needs your current password',
                    trailing: TextButton(
                      onPressed: () => _removeDialog(context),
                      child: Text('REMOVE', style: ts(12, m: true, c: C.red, w: FontWeight.w800)),
                    ),
                  ),
                  const Divider(color: C.line, height: 20),
                  _row(
                    icon: Icons.logout,
                    color: C.cyan,
                    title: 'Lock now',
                    sub: 'Return to the lock screen',
                    trailing: TextButton(
                      onPressed: onLock,
                      child: Text('LOCK', style: ts(12, m: true, c: C.cyan, w: FontWeight.w800)),
                    ),
                  ),
                ],
              ]),
            ),
            const SectionHeader('Notifications'),
            HudCard(
              child: Column(children: [
                _row(
                  icon: Icons.notifications_active,
                  color: C.cyan,
                  title: 'Allow notifications',
                  sub: 'Required for reminders',
                  trailing: TextButton(
                    onPressed: () async {
                      final ok = await NotificationService.instance.requestPermission();
                      if (context.mounted) toast(context, ok ? 'Notifications allowed' : 'Permission not granted');
                    },
                    child: Text('ALLOW', style: ts(12, m: true, c: C.cyan, w: FontWeight.w800)),
                  ),
                ),
                const Divider(color: C.line, height: 20),
                _row(
                  icon: Icons.alarm_on,
                  color: C.amber,
                  title: 'Exact alarms',
                  sub: 'Makes reminders fire on the exact minute',
                  trailing: TextButton(
                    onPressed: () => NotificationService.instance.requestExactAlarms(),
                    child: Text('ENABLE', style: ts(12, m: true, c: C.amber, w: FontWeight.w800)),
                  ),
                ),
                const Divider(color: C.line, height: 20),
                _row(
                  icon: Icons.send,
                  color: C.green,
                  title: 'Send test alert',
                  sub: 'Checks that notifications work',
                  trailing: TextButton(
                    onPressed: () => NotificationService.instance
                        .showNow('✅ AGENT.OS online', 'Notifications are working.'),
                    child: Text('TEST', style: ts(12, m: true, c: C.green, w: FontWeight.w800)),
                  ),
                ),
              ]),
            ),
            const SectionHeader('Vault'),
            HudCard(
              accent: C.red,
              child: _row(
                icon: Icons.shield,
                color: C.red,
                title: 'Sector 7',
                sub: 'Reserved - coming in a future update',
                trailing: const Icon(Icons.lock_outline, color: C.dim, size: 20),
              ),
            ),
            const SectionHeader('Data'),
            HudCard(
              child: Column(children: [
                _row(
                  icon: Icons.history,
                  color: C.dim,
                  title: 'Clear notification history',
                  sub: '${s.notifs.where((n) => n.status != 'pending').length} entries',
                  trailing: TextButton(
                    onPressed: () => s.clearNotifHistory(),
                    child: Text('CLEAR', style: ts(12, m: true, c: C.dim, w: FontWeight.w800)),
                  ),
                ),
                const Divider(color: C.line, height: 20),
                _row(
                  icon: Icons.checklist,
                  color: C.dim,
                  title: 'Clear mission history',
                  sub: '${s.tasks.where((t) => t.status != 'active').length} entries',
                  trailing: TextButton(
                    onPressed: () => s.clearTaskHistory(),
                    child: Text('CLEAR', style: ts(12, m: true, c: C.dim, w: FontWeight.w800)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 24),
            Center(child: Text('AGENT.OS  v1.0', style: ts(11, m: true, c: C.dim, ls: 2))),
          ]);
        },
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String sub,
    required Widget trailing,
  }) =>
      Row(children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: ts(14.5, w: FontWeight.w700)),
            Text(sub, style: ts(11.5, c: C.dim)),
          ]),
        ),
        trailing,
      ]);

  void _removeDialog(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.surface,
        title: Text('REMOVE PASSWORD', style: ts(15, m: true, w: FontWeight.w800, ls: 1.5)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: ts(15, m: true),
          decoration: deco('Current password'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('CANCEL', style: ts(12, m: true, c: C.dim))),
          TextButton(
            onPressed: () async {
              final app = AppState.instance;
              if (app.auth.verifyNormal(ctrl.text)) {
                await app.auth.removeNormal();
                app.refreshUi();
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) toast(context, 'Password removed');
              } else {
                toast(ctx, 'Wrong password');
              }
            },
            child: Text('REMOVE', style: ts(12, m: true, c: C.red, w: FontWeight.w800)),
          ),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }
}

class _PasswordForm extends StatefulWidget {
  final bool change;
  const _PasswordForm({required this.change});
  @override
  State<_PasswordForm> createState() => _PasswordFormState();
}

class _PasswordFormState extends State<_PasswordForm> {
  final _old = TextEditingController();
  final _a = TextEditingController();
  final _b = TextEditingController();

  @override
  void dispose() {
    _old.dispose();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.change ? 'CHANGE PASSWORD' : 'SET PASSWORD', style: ts(16, m: true, w: FontWeight.w800, ls: 2)),
      const SizedBox(height: 16),
      if (widget.change) ...[
        TextField(controller: _old, obscureText: true, style: ts(15, m: true), decoration: deco('Current password', icon: Icons.key)),
        const SizedBox(height: 12),
      ],
      TextField(controller: _a, obscureText: true, style: ts(15, m: true), decoration: deco('New password (min 4)', icon: Icons.lock)),
      const SizedBox(height: 12),
      TextField(controller: _b, obscureText: true, style: ts(15, m: true), decoration: deco('Repeat password', icon: Icons.lock_outline)),
      const SizedBox(height: 22),
      NeonButton('SAVE', icon: Icons.check, onTap: () async {
        final app = AppState.instance;
        if (widget.change && !app.auth.verifyNormal(_old.text)) {
          toast(context, 'Current password is wrong');
          return;
        }
        if (_a.text.length < 4) {
          toast(context, 'Use at least 4 characters');
          return;
        }
        if (_a.text != _b.text) {
          toast(context, 'Passwords do not match');
          return;
        }
        if (app.auth.hasSecret && app.auth.verify(_a.text) == AuthResult.secret) {
          toast(context, 'Choose a different password');
          return;
        }
        await app.auth.setNormal(_a.text);
        app.refreshUi();
        if (context.mounted) {
          Navigator.pop(context);
          toast(context, 'Password saved');
        }
      }),
    ]);
  }
}

// ===== main.dart =====
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  await AppState.instance.init();
  final p = AppState.instance.prefs;
  if (!(p.getBool('asked_notif') ?? false)) {
    await p.setBool('asked_notif', true);
    NotificationService.instance.requestPermission();
  }
  runApp(const AgentApp());
}

class AgentApp extends StatelessWidget {
  const AgentApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AGENT.OS',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const RootGate(),
      );
}
