import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = WorkspaceController();
  await controller.load();
  runApp(PrimeYardWorkspaceApp(controller: controller));
}

class PrimeYardWorkspaceApp extends StatelessWidget {
  final WorkspaceController controller;
  const PrimeYardWorkspaceApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'PrimeYard Workspace',
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppPalette.green,
              primary: AppPalette.green,
              secondary: AppPalette.gold,
              surface: Colors.white,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: AppPalette.canvas,
            cardTheme: CardThemeData(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(color: AppPalette.border),
              ),
              margin: EdgeInsets.zero,
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: AppPalette.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: AppPalette.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: AppPalette.green, width: 1.5),
              ),
            ),
          ),
          home: controller.session.isLoggedIn
              ? HomeShell(controller: controller)
              : LoginScreen(controller: controller),
        );
      },
    );
  }
}

class AppPalette {
  static const green = Color(0xFF1A6B30);
  static const deepGreen = Color(0xFF0D3B1A);
  static const gold = Color(0xFFF2B632);
  static const khaki = Color(0xFFD9CFB8);
  static const canvas = Color(0xFFF6F4EE);
  static const border = Color(0xFFE7E1D5);
  static const text = Color(0xFF1E1E1E);
  static const muted = Color(0xFF6F6A63);
}


class PrimeYardRemoteService {
  PrimeYardRemoteService(this.prefs) {
    _idToken = prefs.getString(_idTokenKey);
    _refreshToken = prefs.getString(_refreshTokenKey);
    final expiryRaw = prefs.getString(_expiryKey);
    if (expiryRaw != null && expiryRaw.isNotEmpty) {
      _expiry = DateTime.tryParse(expiryRaw);
    }
  }

  static const _apiKey = 'AIzaSyCBOobo6kK3Yq92NSglZfHVKGm0wGW1gps';
  static const _projectId = 'primeyard-workspace';
  static const _idTokenKey = 'firebaseIdToken';
  static const _refreshTokenKey = 'firebaseRefreshToken';
  static const _expiryKey = 'firebaseExpiry';

  final SharedPreferences prefs;

  String? _idToken;
  String? _refreshToken;
  DateTime? _expiry;

  Uri get _sharedStateUri => Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents/primeyard/sharedState',
      );

  Future<void> ensureSignedIn() async {
    if (_idToken != null && _expiry != null && _expiry!.isAfter(DateTime.now().add(const Duration(minutes: 2)))) {
      return;
    }
    if (_refreshToken != null && _refreshToken!.isNotEmpty) {
      try {
        await _refreshSession();
        return;
      } catch (_) {}
    }
    await _anonymousSignIn();
  }

  Future<Map<String, dynamic>?> fetchSharedState() async {
    await ensureSignedIn();
    final response = await http.get(_sharedStateUri, headers: _headers());
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) {
      final body = response.body;
      if (body.contains('NOT_FOUND')) return null;
      throw Exception('Cloud load failed (${response.statusCode})');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final fields = Map<String, dynamic>.from(payload['fields'] ?? const {});
    return _decodeFirestoreFields(fields);
  }

  Future<void> saveSharedState(Map<String, dynamic> state) async {
    await ensureSignedIn();
    final response = await http.patch(
      _sharedStateUri,
      headers: {
        ..._headers(),
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'fields': _encodeFirestoreFields(state)}),
    );
    if (response.statusCode >= 400) {
      throw Exception('Cloud save failed (${response.statusCode})');
    }
  }

  Map<String, String> _headers() => {
        'Authorization': 'Bearer $_idToken',
      };

  Future<void> _anonymousSignIn() async {
    final response = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$_apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'returnSecureToken': true}),
    );
    if (response.statusCode >= 400) {
      throw Exception('Firebase auth failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _idToken = data['idToken'] as String?;
    _refreshToken = data['refreshToken'] as String?;
    final expiresIn = int.tryParse('${data['expiresIn'] ?? '3600'}') ?? 3600;
    _expiry = DateTime.now().add(Duration(seconds: expiresIn));
    await _persistSession();
  }

  Future<void> _refreshSession() async {
    final response = await http.post(
      Uri.parse('https://securetoken.googleapis.com/v1/token?key=$_apiKey'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(_refreshToken!)}',
    );
    if (response.statusCode >= 400) {
      throw Exception('Firebase token refresh failed (${response.statusCode})');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    _idToken = data['access_token'] as String?;
    _refreshToken = data['refresh_token'] as String? ?? _refreshToken;
    final expiresIn = int.tryParse('${data['expires_in'] ?? '3600'}') ?? 3600;
    _expiry = DateTime.now().add(Duration(seconds: expiresIn));
    await _persistSession();
  }

  Future<void> _persistSession() async {
    if (_idToken != null) await prefs.setString(_idTokenKey, _idToken!);
    if (_refreshToken != null) await prefs.setString(_refreshTokenKey, _refreshToken!);
    if (_expiry != null) await prefs.setString(_expiryKey, _expiry!.toIso8601String());
  }
}

Map<String, dynamic> _encodeFirestoreFields(Map<String, dynamic> source) {
  return source.map((key, value) => MapEntry(key, _encodeFirestoreValue(value)));
}

Map<String, dynamic> _encodeFirestoreValue(dynamic value) {
  if (value == null) return {'nullValue': null};
  if (value is bool) return {'booleanValue': value};
  if (value is int) return {'integerValue': '$value'};
  if (value is double) return {'doubleValue': value};
  if (value is num) {
    return value == value.roundToDouble() ? {'integerValue': '${value.toInt()}'} : {'doubleValue': value.toDouble()};
  }
  if (value is String) return {'stringValue': value};
  if (value is List) {
    return {
      'arrayValue': {
        'values': value.map(_encodeFirestoreValue).toList(),
      }
    };
  }
  if (value is Map) {
    return {
      'mapValue': {
        'fields': _encodeFirestoreFields(Map<String, dynamic>.from(value)),
      }
    };
  }
  return {'stringValue': value.toString()};
}

Map<String, dynamic> _decodeFirestoreFields(Map<String, dynamic> fields) {
  return fields.map((key, value) => MapEntry(key, _decodeFirestoreValue(Map<String, dynamic>.from(value as Map))));
}

dynamic _decodeFirestoreValue(Map<String, dynamic> value) {
  if (value.containsKey('nullValue')) return null;
  if (value.containsKey('stringValue')) return value['stringValue'];
  if (value.containsKey('booleanValue')) return value['booleanValue'] == true;
  if (value.containsKey('integerValue')) return int.tryParse('${value['integerValue']}') ?? 0;
  if (value.containsKey('doubleValue')) return (value['doubleValue'] as num).toDouble();
  if (value.containsKey('timestampValue')) return value['timestampValue'];
  if (value.containsKey('mapValue')) {
    final fields = Map<String, dynamic>.from((value['mapValue'] as Map<String, dynamic>)['fields'] ?? const {});
    return _decodeFirestoreFields(fields);
  }
  if (value.containsKey('arrayValue')) {
    final values = List<Map<String, dynamic>>.from(((value['arrayValue'] as Map<String, dynamic>)['values'] ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map)));
    return values.map(_decodeFirestoreValue).toList();
  }
  return null;
}

String _hashPassword(String input) => sha256.convert(utf8.encode(input)).toString();


class WorkspaceController extends ChangeNotifier {
  WorkspaceSession session = const WorkspaceSession();
  List<ClientItem> clients = [];
  List<InvoiceItem> invoices = [];
  List<JobItem> jobs = [];
  List<EmployeeItem> employees = [];
  List<EquipmentItem> equipment = [];
  List<UserItem> users = [];

  bool remoteReady = false;
  bool remoteBusy = false;
  String? remoteError;
  Map<String, dynamic> _remoteDocCache = {};
  PrimeYardRemoteService? _remote;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    session = WorkspaceSession(
      isLoggedIn: prefs.getBool('loggedIn') ?? false,
      username: prefs.getString('username') ?? '',
      displayName: prefs.getString('displayName') ?? '',
      role: prefs.getString('role') ?? 'admin',
    );

    clients = _decodeList<ClientItem>(
      prefs.getString('clients'),
      ClientItem.fromMap,
      fallback: _seedClients,
    );
    invoices = _decodeList<InvoiceItem>(
      prefs.getString('invoices'),
      InvoiceItem.fromMap,
      fallback: _seedInvoices,
    );
    jobs = _decodeList<JobItem>(
      prefs.getString('jobs'),
      JobItem.fromMap,
      fallback: _seedJobs,
    );
    employees = _decodeList<EmployeeItem>(
      prefs.getString('employees'),
      EmployeeItem.fromMap,
      fallback: _seedEmployees,
    );
    equipment = _decodeList<EquipmentItem>(
      prefs.getString('equipment'),
      EquipmentItem.fromMap,
      fallback: _seedEquipment,
    );
    users = _decodeList<UserItem>(
      prefs.getString('users'),
      UserItem.fromMap,
      fallback: _seedUsers,
    );

    _ensureAdminUser();
    notifyListeners();
    await _initRemote(prefs);
  }

  List<T> _decodeList<T>(
    String? raw,
    T Function(Map<String, dynamic>) fromMap, {
    required List<T> fallback,
  }) {
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => fromMap(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return fallback;
    }
  }

  List<T> _decodeDynamicList<T>(dynamic raw, T Function(Map<String, dynamic>) fromMap, {required List<T> fallback}) {
    if (raw is! List) return fallback;
    try {
      return raw.map((e) => fromMap(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _initRemote(SharedPreferences prefs) async {
    _remote = PrimeYardRemoteService(prefs);
    try {
      remoteBusy = true;
      notifyListeners();
      await _remote!.ensureSignedIn();
      final remoteState = await _remote!.fetchSharedState();
      if (remoteState != null) {
        _applyRemoteState(remoteState, notify: false);
      } else {
        _remoteDocCache = {};
        await _pushRemote();
      }
      remoteReady = true;
      remoteError = null;
      await _save(pushRemote: false);
    } catch (e) {
      remoteReady = false;
      remoteError = 'Firebase sync unavailable. Using local device data for now.';
      await _save(pushRemote: false);
    } finally {
      remoteBusy = false;
      notifyListeners();
    }
  }

  void _applyRemoteState(Map<String, dynamic> state, {bool notify = true}) {
    _remoteDocCache = Map<String, dynamic>.from(state);
    clients = _decodeDynamicList<ClientItem>(state['clients'], ClientItem.fromMap, fallback: clients.isNotEmpty ? clients : _seedClients);
    invoices = _decodeDynamicList<InvoiceItem>(state['invoices'], InvoiceItem.fromMap, fallback: invoices.isNotEmpty ? invoices : _seedInvoices);
    jobs = _decodeDynamicList<JobItem>(state['jobs'], JobItem.fromMap, fallback: jobs.isNotEmpty ? jobs : _seedJobs);
    employees = _decodeDynamicList<EmployeeItem>(state['emps'], EmployeeItem.fromMap, fallback: employees.isNotEmpty ? employees : _seedEmployees);
    equipment = _decodeDynamicList<EquipmentItem>(state['equipment'], EquipmentItem.fromMap, fallback: equipment.isNotEmpty ? equipment : _seedEquipment);
    users = _decodeDynamicList<UserItem>(state['users'], UserItem.fromMap, fallback: users.isNotEmpty ? users : _seedUsers);
    _ensureAdminUser();
    if (session.isLoggedIn) {
      final liveUser = users.where((u) => u.username.toLowerCase() == session.username.toLowerCase()).toList();
      if (liveUser.isNotEmpty) {
        session = WorkspaceSession(
          isLoggedIn: true,
          username: liveUser.first.username,
          displayName: liveUser.first.displayName,
          role: liveUser.first.role,
        );
      }
    }
    if (notify) notifyListeners();
  }

  void _ensureAdminUser() {
    final adminHash = _hashPassword('PrimeYard2025');
    final hasAdmin = users.any((u) => u.username.toLowerCase() == 'admin');
    if (!hasAdmin) {
      users = [
        UserItem(
          id: 'admin',
          displayName: 'Owner',
          username: 'admin',
          role: 'master_admin',
          passwordHash: adminHash,
        ),
        ...users,
      ];
      return;
    }
    users = users
        .map(
          (u) => u.username.toLowerCase() == 'admin'
              ? u.copyWith(passwordHash: u.passwordHash.isEmpty ? adminHash : u.passwordHash, role: u.role == 'admin' ? 'master_admin' : u.role)
              : u,
        )
        .toList();
  }

  Future<void> _save({bool pushRemote = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('loggedIn', session.isLoggedIn);
    await prefs.setString('username', session.username);
    await prefs.setString('displayName', session.displayName);
    await prefs.setString('role', session.role);
    await prefs.setString('clients', jsonEncode(clients.map((e) => e.toMap()).toList()));
    await prefs.setString('invoices', jsonEncode(invoices.map((e) => e.toMap()).toList()));
    await prefs.setString('jobs', jsonEncode(jobs.map((e) => e.toMap()).toList()));
    await prefs.setString('employees', jsonEncode(employees.map((e) => e.toMap()).toList()));
    await prefs.setString('equipment', jsonEncode(equipment.map((e) => e.toMap()).toList()));
    await prefs.setString('users', jsonEncode(users.map((e) => e.toMap()).toList()));
    if (pushRemote) {
      await _pushRemote();
    }
  }

  Future<void> _pushRemote() async {
    if (_remote == null) return;
    try {
      remoteBusy = true;
      notifyListeners();
      final merged = <String, dynamic>{
        ..._remoteDocCache,
        'clients': clients.map((e) => e.toMap()).toList(),
        'invoices': invoices.map((e) => e.toMap()).toList(),
        'jobs': jobs.map((e) => e.toMap()).toList(),
        'emps': employees.map((e) => e.toMap()).toList(),
        'equipment': equipment.map((e) => e.toMap()).toList(),
        'users': users.map((e) => e.toMap()).toList(),
        'updatedAt': DateTime.now().toIso8601String(),
        'updatedBy': session.username.isEmpty ? 'mobile_app' : session.username,
      };
      await _remote!.saveSharedState(merged);
      _remoteDocCache = merged;
      remoteReady = true;
      remoteError = null;
    } catch (_) {
      remoteError = 'Saved on this device, but Firebase sync failed.';
    } finally {
      remoteBusy = false;
      notifyListeners();
    }
  }

  Future<void> signIn({required String username, required String password}) async {
    final normalized = username.trim().toLowerCase();
    final hashed = _hashPassword(password);
    UserItem? user;
    for (final candidate in users) {
      if (candidate.username.trim().toLowerCase() != normalized) continue;
      if (candidate.passwordHash.isEmpty || candidate.passwordHash == hashed) {
        user = candidate;
        break;
      }
    }
    if (user == null) {
      throw Exception('Incorrect username or password.');
    }
    session = WorkspaceSession(
      isLoggedIn: true,
      username: user.username,
      displayName: user.displayName,
      role: user.role,
    );
    await _save(pushRemote: false);
    notifyListeners();
  }

  Future<void> signOut() async {
    session = const WorkspaceSession();
    await _save(pushRemote: false);
    notifyListeners();
  }

  Future<void> addClient(ClientItem item) async {
    clients = [item, ...clients];
    await _save();
    notifyListeners();
  }

  Future<void> addInvoice(InvoiceItem item) async {
    invoices = [item, ...invoices];
    await _save();
    notifyListeners();
  }

  Future<void> addJob(JobItem item) async {
    jobs = [item, ...jobs];
    await _save();
    notifyListeners();
  }

  Future<void> toggleJob(String id) async {
    jobs = jobs
        .map((e) => e.id == id ? e.copyWith(completed: !e.completed) : e)
        .toList();
    await _save();
    notifyListeners();
  }

  Future<void> updateEquipmentStatus(String id, EquipmentStatus status, String note) async {
    equipment = equipment
        .map((e) => e.id == id ? e.copyWith(status: status, note: note) : e)
        .toList();
    await _save();
    notifyListeners();
  }

  Future<void> addEmployee(EmployeeItem item) async {
    employees = [item, ...employees];
    await _save();
    notifyListeners();
  }

  Future<void> addUser(UserItem item) async {
    users = [item, ...users];
    await _save();
    notifyListeners();
  }

  double get monthlyRevenue => invoices.fold<double>(0, (sum, e) => sum + e.amount);
  int get activeClients => clients.where((e) => e.active).length;
  int get jobsToday => jobs.where((e) => e.dayLabel == 'Today').length;
  int get openIssues => equipment.where((e) => e.status != EquipmentStatus.ok).length;

  List<ClientItem> get _seedClients => [
        ClientItem(
          id: _id(),
          name: 'Greenstone Office Park',
          area: 'Hillcrest',
          phone: '082 000 1001',
          service: 'Commercial grounds maintenance',
          active: true,
        ),
        ClientItem(
          id: _id(),
          name: 'Naidoo Residence',
          area: 'Kloof',
          phone: '082 000 1002',
          service: 'Weekly lawn and garden care',
          active: true,
        ),
        ClientItem(
          id: _id(),
          name: 'Copesville Property',
          area: 'Pietermaritzburg',
          phone: '082 000 1003',
          service: 'Cleanup and waste removal',
          active: false,
        ),
      ];

  List<InvoiceItem> get _seedInvoices => [
        InvoiceItem(id: _id(), clientName: 'Greenstone Office Park', amount: 4800, status: 'Sent', date: '2026-03-18'),
        InvoiceItem(id: _id(), clientName: 'Naidoo Residence', amount: 1450, status: 'Paid', date: '2026-03-17'),
        InvoiceItem(id: _id(), clientName: 'Copesville Property', amount: 2200, status: 'Due', date: '2026-03-16'),
      ];

  List<JobItem> get _seedJobs => [
        JobItem(id: _id(), title: 'Morning cut and edge', area: 'Upper Highway', dayLabel: 'Today', team: 'Team A', completed: false),
        JobItem(id: _id(), title: 'Hedge trim and cleanup', area: 'Durban North', dayLabel: 'Today', team: 'Team B', completed: false),
        JobItem(id: _id(), title: 'Waste removal', area: 'Pietermaritzburg', dayLabel: 'Tomorrow', team: 'Team A', completed: false),
      ];

  List<EmployeeItem> get _seedEmployees => [
        EmployeeItem(id: _id(), name: 'Siyabonga M', role: 'Supervisor', leaveDays: 8, phone: '082 111 1111'),
        EmployeeItem(id: _id(), name: 'Lindo N', role: 'Grounds staff', leaveDays: 11, phone: '082 111 1112'),
        EmployeeItem(id: _id(), name: 'Ntokozo Z', role: 'Grounds staff', leaveDays: 10, phone: '082 111 1113'),
      ];

  List<EquipmentItem> get _seedEquipment => [
        EquipmentItem(id: _id(), name: 'Brush cutter', status: EquipmentStatus.ok, note: ''),
        EquipmentItem(id: _id(), name: 'Lawn mower', status: EquipmentStatus.issue, note: 'Blade vibration to inspect'),
        EquipmentItem(id: _id(), name: 'Trailer lights', status: EquipmentStatus.missing, note: 'Left light not working'),
      ];

  List<UserItem> get _seedUsers => [
        UserItem(id: 'admin', displayName: 'Owner', username: 'admin', role: 'master_admin', passwordHash: _hashPassword('PrimeYard2025')),
        UserItem(id: _id(), displayName: 'Site Supervisor', username: 'supervisor', role: 'supervisor', passwordHash: ''),
      ];
}

String _id() => DateTime.now().microsecondsSinceEpoch.toString();

class WorkspaceSession {
  final bool isLoggedIn;
  final String username;
  final String displayName;
  final String role;
  const WorkspaceSession({
    this.isLoggedIn = false,
    this.username = '',
    this.displayName = '',
    this.role = 'admin',
  });
}

class HomeShell extends StatefulWidget {
  final WorkspaceController controller;
  const HomeShell({super.key, required this.controller});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;

  static const items = [
    _NavMeta('Dashboard', Icons.dashboard_rounded),
    _NavMeta('Quotes', Icons.calculate_rounded),
    _NavMeta('Clients', Icons.groups_rounded),
    _NavMeta('Invoices', Icons.receipt_long_rounded),
    _NavMeta('Schedule', Icons.route_rounded),
    _NavMeta('Equipment', Icons.handyman_rounded),
    _NavMeta('Employees', Icons.badge_rounded),
    _NavMeta('Users', Icons.admin_panel_settings_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 980;
    final body = _buildPage();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppPalette.border),
              ),
              padding: const EdgeInsets.all(6),
              child: Image.asset('assets/logo-mark.png', fit: BoxFit.contain),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(items[index].label, style: const TextStyle(fontWeight: FontWeight.w800, color: AppPalette.text)),
                  Text(
                    'PrimeYard staff workspace',
                    style: TextStyle(fontSize: 12, color: AppPalette.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: AppPalette.deepGreen,
              child: Text(
                widget.controller.session.displayName.isEmpty
                    ? 'P'
                    : widget.controller.session.displayName.trim().substring(0, 1).toUpperCase(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          )
        ],
      ),
      drawer: wide ? null : Drawer(child: _drawerContent()),
      body: Row(
        children: [
          if (wide)
            Container(
              width: 280,
              margin: const EdgeInsets.fromLTRB(18, 0, 0, 18),
              child: _drawerContent(),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: body,
            ),
          ),
        ],
      ),
      bottomNavigationBar: null,
    );
  }

  Widget _drawerContent() {
    return Card(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: AppPalette.deepGreen,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.asset('assets/logo-full.png', height: 40, fit: BoxFit.contain),
                    const SizedBox(height: 12),
                    const Text(
                      'Your property, our pride.',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.08),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.controller.session.displayName,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.controller.session.role.replaceAll('_', ' '),
                                  style: TextStyle(color: Colors.white.withOpacity(.72), fontSize: 12),
                                )
                              ],
                            ),
                          ),
                          const Icon(Icons.verified_user_rounded, color: AppPalette.gold),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              ...List.generate(items.length, (i) {
                final selected = i == index;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: selected ? AppPalette.khaki : Colors.white,
                      foregroundColor: AppPalette.text,
                      alignment: Alignment.centerLeft,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(color: selected ? AppPalette.green : AppPalette.border),
                      ),
                    ),
                    onPressed: () {
                      Navigator.maybePop(context);
                      setState(() => index = i);
                    },
                    icon: Icon(items[i].icon, color: selected ? AppPalette.green : AppPalette.muted),
                    label: Text(items[i].label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                );
              }),
              const Spacer(),
              Center(
                child: Image.asset('assets/mascot.png', height: 165, fit: BoxFit.contain),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  side: BorderSide(color: AppPalette.border),
                ),
                onPressed: () async => widget.controller.signOut(),
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPage() {
    switch (index) {
      case 0:
        return DashboardScreen(controller: widget.controller, onJump: (v) => setState(() => index = v));
      case 1:
        return QuotesScreen(controller: widget.controller);
      case 2:
        return ClientsScreen(controller: widget.controller);
      case 3:
        return InvoicesScreen(controller: widget.controller);
      case 4:
        return ScheduleScreen(controller: widget.controller);
      case 5:
        return EquipmentScreen(controller: widget.controller);
      case 6:
        return EmployeesScreen(controller: widget.controller);
      case 7:
        return UsersScreen(controller: widget.controller);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _NavMeta {
  final String label;
  final IconData icon;
  const _NavMeta(this.label, this.icon);
}


class LoginScreen extends StatefulWidget {
  final WorkspaceController controller;
  const LoginScreen({super.key, required this.controller});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController(text: 'admin');
  final password = TextEditingController(text: 'PrimeYard2025');
  bool loading = false;
  String? errorText;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.of(context).size.width < 760;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: mobile
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _brandPanel(compact: true),
                              const SizedBox(height: 18),
                              _loginCard(),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 11, child: _brandPanel()),
                              const SizedBox(width: 22),
                              Expanded(flex: 9, child: _loginCard()),
                            ],
                          ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _brandPanel({bool compact = false}) {
    return Card(
      child: Container(
        padding: EdgeInsets.all(compact ? 24 : 36),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            colors: [AppPalette.deepGreen, AppPalette.green],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: compact
            ? Column(
                children: [
                  Image.asset('assets/logo-full.png', height: 54),
                  const SizedBox(height: 12),
                  const Text('Staff workspace', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(
                    'Native mobile workspace with proper persistence, bigger touch targets, and Firebase cloud sync for your shared business data.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withOpacity(.82), height: 1.45),
                  ),
                  const SizedBox(height: 12),
                  Image.asset('assets/mascot.png', height: 200),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Image.asset('assets/logo-full.png', height: 64),
                  const SizedBox(height: 24),
                  const Text(
                    'A proper PrimeYard workspace app.',
                    style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900, height: 1.05),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Built for staff and admin use with cleaner navigation, larger mobile controls, persistent sign-in, and direct Firebase backend sync.',
                    style: TextStyle(color: Colors.white.withOpacity(.84), fontSize: 15, height: 1.55),
                  ),
                  const SizedBox(height: 22),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: const [
                      FeatureChip(label: 'Remembers login'),
                      FeatureChip(label: 'Cloud-connected'),
                      FeatureChip(label: 'Quotes & invoices'),
                      FeatureChip(label: 'Routes & equipment'),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Image.asset('assets/mascot.png', height: 360),
                    ),
                  )
                ],
              ),
      ),
    );
  }

  Widget _loginCard() {
    final controller = widget.controller;
    final syncColor = controller.remoteError == null ? const Color(0xFF1F7A33) : const Color(0xFFC62828);
    final syncText = controller.remoteBusy
        ? 'Connecting to Firebase…'
        : controller.remoteError ?? 'Firebase connected. Use your PrimeYard staff login.';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Welcome back', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text('Use your staff account to access the PrimeYard workspace.', style: TextStyle(color: AppPalette.muted, height: 1.45)),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: syncColor.withOpacity(.08),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: syncColor.withOpacity(.18)),
              ),
              child: Row(
                children: [
                  Icon(controller.remoteError == null ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: syncColor),
                  const SizedBox(width: 10),
                  Expanded(child: Text(syncText, style: TextStyle(color: syncColor, fontWeight: FontWeight.w700))),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextField(controller: username, decoration: const InputDecoration(labelText: 'Username')),
            const SizedBox(height: 12),
            TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
            if (errorText != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEBEE),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFFFCDD2)),
                ),
                child: Text(errorText!, style: const TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w700)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(58),
                backgroundColor: AppPalette.green,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              onPressed: loading
                  ? null
                  : () async {
                      setState(() {
                        loading = true;
                        errorText = null;
                      });
                      try {
                        await widget.controller.signIn(username: username.text, password: password.text);
                      } catch (e) {
                        setState(() => errorText = e.toString().replaceFirst('Exception: ', ''));
                      } finally {
                        if (mounted) {
                          setState(() => loading = false);
                        }
                      }
                    },
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(loading ? 'Signing in...' : 'Sign in'),
            ),
            const SizedBox(height: 12),
            Text(
              'Default owner login: admin / PrimeYard2025',
              style: TextStyle(color: AppPalette.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  final WorkspaceController controller;
  final ValueChanged<int> onJump;
  const DashboardScreen({super.key, required this.controller, required this.onJump});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 1040;
    return ListView(
      children: [
        const SizedBox(height: 6),
        Text('Good day, ${controller.session.displayName}.', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text('Here is your business snapshot for the day.', style: TextStyle(color: AppPalette.muted)),
        const SizedBox(height: 18),
        GridView.count(
          crossAxisCount: wide ? 4 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          childAspectRatio: wide ? 1.5 : 1.15,
          children: [
            StatCard(title: 'Active clients', value: '${controller.activeClients}', icon: Icons.groups_rounded),
            StatCard(title: 'Invoices total', value: 'R ${controller.monthlyRevenue.toStringAsFixed(0)}', icon: Icons.payments_rounded),
            StatCard(title: 'Jobs today', value: '${controller.jobsToday}', icon: Icons.route_rounded),
            StatCard(title: 'Open equipment issues', value: '${controller.openIssues}', icon: Icons.warning_amber_rounded),
          ],
        ),
        const SizedBox(height: 18),
        wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DashboardPanel(
                      title: 'Quick actions',
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          ActionChipButton(label: 'New quote', icon: Icons.calculate_rounded, onTap: () => onJump(1)),
                          ActionChipButton(label: 'Add client', icon: Icons.person_add_alt_1_rounded, onTap: () => onJump(2)),
                          ActionChipButton(label: 'Create invoice', icon: Icons.receipt_long_rounded, onTap: () => onJump(3)),
                          ActionChipButton(label: 'Check equipment', icon: Icons.handyman_rounded, onTap: () => onJump(5)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: const _CoveragePanel()),
                ],
              )
            : Column(
                children: [
                  DashboardPanel(
                    title: 'Quick actions',
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        ActionChipButton(label: 'New quote', icon: Icons.calculate_rounded, onTap: () => onJump(1)),
                        ActionChipButton(label: 'Add client', icon: Icons.person_add_alt_1_rounded, onTap: () => onJump(2)),
                        ActionChipButton(label: 'Create invoice', icon: Icons.receipt_long_rounded, onTap: () => onJump(3)),
                        ActionChipButton(label: 'Check equipment', icon: Icons.handyman_rounded, onTap: () => onJump(5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const _CoveragePanel(),
                ],
              ),
        const SizedBox(height: 18),
        wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DashboardPanel(
                      title: 'Today’s schedule',
                      child: Column(
                        children: controller.jobs.take(3).map((job) => JobTile(job: job)).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: DashboardPanel(
                      title: 'Recent invoices',
                      child: Column(
                        children: controller.invoices.take(3).map((invoice) => InvoiceTile(invoice: invoice)).toList(),
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  DashboardPanel(
                    title: 'Today’s schedule',
                    child: Column(children: controller.jobs.take(3).map((job) => JobTile(job: job)).toList()),
                  ),
                  const SizedBox(height: 14),
                  DashboardPanel(
                    title: 'Recent invoices',
                    child: Column(children: controller.invoices.take(3).map((invoice) => InvoiceTile(invoice: invoice)).toList()),
                  ),
                ],
              ),
      ],
    );
  }
}


class _CoveragePanel extends StatelessWidget {
  const _CoveragePanel();

  @override
  Widget build(BuildContext context) {
    return DashboardPanel(
      title: 'Coverage area',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Durban, Pietermaritzburg, Upper Highway and surrounding areas within roughly a 50 km working radius.',
            style: TextStyle(color: AppPalette.muted, height: 1.5),
          ),
          const SizedBox(height: 14),
          Container(
            height: 170,
            decoration: BoxDecoration(
              color: AppPalette.canvas,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppPalette.border),
            ),
            child: Stack(
              children: const [
                Positioned(left: 28, top: 44, child: MapDot(label: 'Durban')),
                Positioned(right: 34, top: 58, child: MapDot(label: 'Upper Highway')),
                Positioned(left: 90, bottom: 32, child: MapDot(label: 'Pietermaritzburg')),
                Positioned(right: 58, bottom: 40, child: MapDot(label: 'Surrounding areas')),
              ],
            ),
          )
        ],
      ),
    );
  }
}

class QuotesScreen extends StatefulWidget {
  final WorkspaceController controller;
  const QuotesScreen({super.key, required this.controller});

  @override
  State<QuotesScreen> createState() => _QuotesScreenState();
}

class _QuotesScreenState extends State<QuotesScreen> {
  double sqm = 250;
  String frequency = 'Weekly';
  bool hedges = false;
  bool wasteRemoval = false;
  bool pressureCleaning = false;

  double get total {
    double base = sqm * 4.8;
    if (frequency == 'Fortnightly') base *= 1.15;
    if (frequency == 'Monthly') base *= 1.35;
    if (hedges) base += 420;
    if (wasteRemoval) base += 580;
    if (pressureCleaning) base += 760;
    return base;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Quote calculator',
          subtitle: 'Fast mobile-first pricing for lawn, garden, cleanup and property services.',
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Property size', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Slider(
                  value: sqm,
                  min: 50,
                  max: 2000,
                  divisions: 39,
                  label: sqm.round().toString(),
                  onChanged: (v) => setState(() => sqm = v),
                ),
                Text('${sqm.round()} m²', style: TextStyle(color: AppPalette.muted)),
                const SizedBox(height: 20),
                const Text('Visit frequency', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  children: ['Weekly', 'Fortnightly', 'Monthly']
                      .map((e) => ChoiceChip(
                            label: Text(e),
                            selected: frequency == e,
                            onSelected: (_) => setState(() => frequency = e),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 20),
                const Text('Add-on services', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 8),
                SwitchListTile(
                  value: hedges,
                  onChanged: (v) => setState(() => hedges = v),
                  title: const Text('Hedge trimming'),
                  subtitle: const Text('Shaping and line finishing for garden edges'),
                ),
                SwitchListTile(
                  value: wasteRemoval,
                  onChanged: (v) => setState(() => wasteRemoval = v),
                  title: const Text('Waste removal'),
                  subtitle: const Text('Green waste loading and disposal run'),
                ),
                SwitchListTile(
                  value: pressureCleaning,
                  onChanged: (v) => setState(() => pressureCleaning = v),
                  title: const Text('Pressure cleaning'),
                  subtitle: const Text('Paving, yard or entrance wash-down'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: AppPalette.deepGreen,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Estimated monthly value', style: TextStyle(color: Colors.white.withOpacity(.72))),
                const SizedBox(height: 8),
                Text('R ${total.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w900)),
                const SizedBox(height: 16),
                Text(
                  'This is a fast estimator. Final price can still account for terrain, access, team size, green waste volume and transport distance.',
                  style: TextStyle(color: Colors.white.withOpacity(.82), height: 1.55),
                )
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ClientsScreen extends StatelessWidget {
  final WorkspaceController controller;
  const ClientsScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Clients',
          subtitle: 'Keep residential and commercial client records in one place.',
          action: FilledButton.icon(
            onPressed: () => _showClientDialog(context, controller),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Add client'),
          ),
        ),
        const SizedBox(height: 14),
        ...controller.clients.map((c) => Card(
              child: ListTile(
                contentPadding: const EdgeInsets.all(18),
                leading: CircleAvatar(backgroundColor: AppPalette.khaki, child: Text(c.name.substring(0, 1))),
                title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${c.service}\n${c.area} · ${c.phone}', style: TextStyle(color: AppPalette.muted, height: 1.5)),
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: c.active ? const Color(0xFFE8F4EA) : const Color(0xFFF4ECE0),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(c.active ? 'Active' : 'Inactive', style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            )),
      ],
    );
  }
}

class InvoicesScreen extends StatelessWidget {
  final WorkspaceController controller;
  const InvoicesScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Invoices',
          subtitle: 'Track sent, due and paid invoices from the mobile app.',
          action: FilledButton.icon(
            onPressed: () => _showInvoiceDialog(context, controller),
            icon: const Icon(Icons.add_card_rounded),
            label: const Text('New invoice'),
          ),
        ),
        const SizedBox(height: 14),
        ...controller.invoices.map((invoice) => InvoiceTile(invoice: invoice, padded: true)),
      ],
    );
  }
}

class ScheduleScreen extends StatelessWidget {
  final WorkspaceController controller;
  const ScheduleScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Route scheduler',
          subtitle: 'Plan the day clearly for teams, areas and service types.',
          action: FilledButton.icon(
            onPressed: () => _showJobDialog(context, controller),
            icon: const Icon(Icons.add_road_rounded),
            label: const Text('Add route job'),
          ),
        ),
        const SizedBox(height: 14),
        ...controller.jobs.map((job) => JobTile(job: job, onToggle: () => controller.toggleJob(job.id), padded: true)),
      ],
    );
  }
}

class EquipmentScreen extends StatelessWidget {
  final WorkspaceController controller;
  const EquipmentScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Equipment checks',
          subtitle: 'Track condition, notes and issues with larger mobile-friendly controls.',
        ),
        const SizedBox(height: 14),
        ...controller.equipment.map(
          (item) => Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18))),
                      StatusBadge(status: item.status),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: EquipmentStatus.values
                        .map((status) => ChoiceChip(
                              label: Text(status.label),
                              selected: item.status == status,
                              onSelected: (_) => controller.updateEquipmentStatus(item.id, status, item.note),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    initialValue: item.note,
                    decoration: const InputDecoration(labelText: 'Notes'),
                    onChanged: (v) => controller.updateEquipmentStatus(item.id, item.status, v),
                  ),
                ],
              ),
            ),
          ),
        )
      ],
    );
  }
}

class EmployeesScreen extends StatelessWidget {
  final WorkspaceController controller;
  const EmployeesScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Employees',
          subtitle: 'Keep team members, roles and leave balances together.',
          action: FilledButton.icon(
            onPressed: () => _showEmployeeDialog(context, controller),
            icon: const Icon(Icons.group_add_rounded),
            label: const Text('Add employee'),
          ),
        ),
        const SizedBox(height: 14),
        ...controller.employees.map(
          (employee) => Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(18),
              leading: CircleAvatar(radius: 24, backgroundColor: AppPalette.deepGreen, child: Text(employee.name.substring(0, 1), style: const TextStyle(color: Colors.white))),
              title: Text(employee.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${employee.role}\n${employee.phone}', style: TextStyle(color: AppPalette.muted, height: 1.5)),
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Leave balance', style: TextStyle(fontSize: 11, color: AppPalette.muted)),
                  Text('${employee.leaveDays} days', style: const TextStyle(fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ),
        )
      ],
    );
  }
}

class UsersScreen extends StatelessWidget {
  final WorkspaceController controller;
  const UsersScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageIntro(
          title: 'Users & access',
          subtitle: 'Staff-only access levels for master admin, admin, supervisor and worker roles.',
          action: FilledButton.icon(
            onPressed: () => _showUserDialog(context, controller),
            icon: const Icon(Icons.person_add_rounded),
            label: const Text('Add user'),
          ),
        ),
        const SizedBox(height: 14),
        ...controller.users.map(
          (user) => Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(18),
              leading: const CircleAvatar(backgroundColor: AppPalette.khaki, child: Icon(Icons.verified_user_rounded)),
              title: Text(user.displayName, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(user.username, style: TextStyle(color: AppPalette.muted)),
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: AppPalette.canvas, borderRadius: BorderRadius.circular(99)),
                child: Text(user.role.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        )
      ],
    );
  }
}

class PageIntro extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? action;
  const PageIntro({super.key, required this.title, required this.subtitle, this.action});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      runAlignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(subtitle, style: TextStyle(color: AppPalette.muted, height: 1.45)),
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

class DashboardPanel extends StatelessWidget {
  final String title;
  final Widget child;
  const DashboardPanel({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  const StatCard({super.key, required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(backgroundColor: AppPalette.canvas, child: Icon(icon, color: AppPalette.green)),
            const Spacer(),
            Text(value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(title, style: TextStyle(color: AppPalette.muted)),
          ],
        ),
      ),
    );
  }
}

class ActionChipButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const ActionChipButton({super.key, required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        backgroundColor: AppPalette.canvas,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class FeatureChip extends StatelessWidget {
  final String label;
  const FeatureChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.08),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: Colors.white.withOpacity(.12)),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
    );
  }
}

class MapDot extends StatelessWidget {
  final String label;
  const MapDot({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: const BoxDecoration(color: AppPalette.green, shape: BoxShape.circle),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(99), border: Border.all(color: AppPalette.border)),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        )
      ],
    );
  }
}

class InvoiceTile extends StatelessWidget {
  final InvoiceItem invoice;
  final bool padded;
  const InvoiceTile({super.key, required this.invoice, this.padded = false});

  @override
  Widget build(BuildContext context) {
    final child = ListTile(
      contentPadding: const EdgeInsets.all(18),
      title: Text(invoice.clientName, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('${invoice.date} · ${invoice.status}', style: TextStyle(color: AppPalette.muted)),
      ),
      trailing: Text('R ${invoice.amount.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
    );
    return padded ? Card(child: child) : child;
  }
}

class JobTile extends StatelessWidget {
  final JobItem job;
  final VoidCallback? onToggle;
  final bool padded;
  const JobTile({super.key, required this.job, this.onToggle, this.padded = false});

  @override
  Widget build(BuildContext context) {
    final tile = ListTile(
      contentPadding: const EdgeInsets.all(18),
      leading: Checkbox(value: job.completed, onChanged: (_) => onToggle?.call()),
      title: Text(job.title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('${job.area} · ${job.team} · ${job.dayLabel}', style: TextStyle(color: AppPalette.muted)),
      ),
    );
    return padded ? Card(child: tile) : tile;
  }
}

class StatusBadge extends StatelessWidget {
  final EquipmentStatus status;
  const StatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      EquipmentStatus.ok => const Color(0xFF1F7A33),
      EquipmentStatus.issue => const Color(0xFFB7791F),
      EquipmentStatus.missing => const Color(0xFFC62828),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withOpacity(.1), borderRadius: BorderRadius.circular(99)),
      child: Text(status.label, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
    );
  }
}

Future<void> _showClientDialog(BuildContext context, WorkspaceController controller) async {
  final name = TextEditingController();
  final area = TextEditingController();
  final phone = TextEditingController();
  final service = TextEditingController();
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Add client'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Client name')),
            const SizedBox(height: 10),
            TextField(controller: area, decoration: const InputDecoration(labelText: 'Area')),
            const SizedBox(height: 10),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 10),
            TextField(controller: service, decoration: const InputDecoration(labelText: 'Service')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await controller.addClient(
              ClientItem(
                id: _id(),
                name: name.text.trim(),
                area: area.text.trim(),
                phone: phone.text.trim(),
                service: service.text.trim(),
                active: true,
              ),
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> _showInvoiceDialog(BuildContext context, WorkspaceController controller) async {
  final client = TextEditingController();
  final amount = TextEditingController();
  final status = TextEditingController(text: 'Sent');
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('New invoice'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: client, decoration: const InputDecoration(labelText: 'Client name')),
            const SizedBox(height: 10),
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')),
            const SizedBox(height: 10),
            TextField(controller: status, decoration: const InputDecoration(labelText: 'Status')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await controller.addInvoice(
              InvoiceItem(
                id: _id(),
                clientName: client.text.trim(),
                amount: double.tryParse(amount.text.trim()) ?? 0,
                status: status.text.trim(),
                date: DateTime.now().toIso8601String().split('T').first,
              ),
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> _showJobDialog(BuildContext context, WorkspaceController controller) async {
  final title = TextEditingController();
  final area = TextEditingController();
  final team = TextEditingController();
  final day = TextEditingController(text: 'Today');
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Add route job'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Job title')),
            const SizedBox(height: 10),
            TextField(controller: area, decoration: const InputDecoration(labelText: 'Area')),
            const SizedBox(height: 10),
            TextField(controller: team, decoration: const InputDecoration(labelText: 'Assigned team')),
            const SizedBox(height: 10),
            TextField(controller: day, decoration: const InputDecoration(labelText: 'Day label')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await controller.addJob(
              JobItem(
                id: _id(),
                title: title.text.trim(),
                area: area.text.trim(),
                team: team.text.trim(),
                dayLabel: day.text.trim(),
                completed: false,
              ),
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> _showEmployeeDialog(BuildContext context, WorkspaceController controller) async {
  final name = TextEditingController();
  final role = TextEditingController();
  final phone = TextEditingController();
  final leave = TextEditingController(text: '10');
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Add employee'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Employee name')),
            const SizedBox(height: 10),
            TextField(controller: role, decoration: const InputDecoration(labelText: 'Role')),
            const SizedBox(height: 10),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
            const SizedBox(height: 10),
            TextField(controller: leave, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Leave days')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await controller.addEmployee(
              EmployeeItem(
                id: _id(),
                name: name.text.trim(),
                role: role.text.trim(),
                phone: phone.text.trim(),
                leaveDays: int.tryParse(leave.text.trim()) ?? 0,
              ),
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> _showUserDialog(BuildContext context, WorkspaceController controller) async {
  final name = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final role = TextEditingController(text: 'worker');
  await showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Add user'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Display name')),
            const SizedBox(height: 10),
            TextField(controller: username, decoration: const InputDecoration(labelText: 'Username')),
            const SizedBox(height: 10),
            TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
            const SizedBox(height: 10),
            TextField(controller: role, decoration: const InputDecoration(labelText: 'Role')),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await controller.addUser(
              UserItem(
                id: _id(),
                displayName: name.text.trim(),
                username: username.text.trim(),
                role: role.text.trim(),
                passwordHash: password.text.trim().isEmpty ? '' : _hashPassword(password.text.trim()),
              ),
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

enum EquipmentStatus { ok, issue, missing }

extension EquipmentStatusX on EquipmentStatus {
  String get label => switch (this) {
        EquipmentStatus.ok => 'OK',
        EquipmentStatus.issue => 'Issue',
        EquipmentStatus.missing => 'Missing',
      };
}


class ClientItem {
  final String id;
  final String name;
  final String area;
  final String phone;
  final String service;
  final bool active;
  final Map<String, dynamic> raw;
  ClientItem({required this.id, required this.name, required this.area, required this.phone, required this.service, required this.active, this.raw = const {}});
  Map<String, dynamic> toMap() => {
        ...raw,
        'id': id,
        'name': name,
        'area': area,
        'phone': phone,
        'contact': phone,
        'service': service,
        'active': active,
      };
  factory ClientItem.fromMap(Map<String, dynamic> map) => ClientItem(
        id: map['id'] ?? _id(),
        name: map['name'] ?? '',
        area: map['area'] ?? '',
        phone: map['phone'] ?? map['contact'] ?? '',
        service: map['service'] ?? map['pkg'] ?? '',
        active: map['active'] ?? true,
        raw: Map<String, dynamic>.from(map),
      );
}

class InvoiceItem {
  final String id;
  final String clientName;
  final double amount;
  final String status;
  final String date;
  final Map<String, dynamic> raw;
  InvoiceItem({required this.id, required this.clientName, required this.amount, required this.status, required this.date, this.raw = const {}});
  Map<String, dynamic> toMap() => {
        ...raw,
        'id': id,
        'clientName': clientName,
        'amount': amount,
        'status': status,
        'date': date,
      };
  factory InvoiceItem.fromMap(Map<String, dynamic> map) => InvoiceItem(
        id: map['id'] ?? _id(),
        clientName: map['clientName'] ?? map['name'] ?? '',
        amount: (map['amount'] ?? 0).toDouble(),
        status: map['status'] ?? 'Sent',
        date: map['date'] ?? map['createdAt'] ?? '',
        raw: Map<String, dynamic>.from(map),
      );
}

class JobItem {
  final String id;
  final String title;
  final String area;
  final String dayLabel;
  final String team;
  final bool completed;
  final Map<String, dynamic> raw;
  JobItem({required this.id, required this.title, required this.area, required this.dayLabel, required this.team, required this.completed, this.raw = const {}});
  Map<String, dynamic> toMap() => {
        ...raw,
        'id': id,
        'title': title,
        'area': area,
        'dayLabel': dayLabel,
        'team': team,
        'completed': completed,
      };
  JobItem copyWith({bool? completed}) => JobItem(
        id: id,
        title: title,
        area: area,
        dayLabel: dayLabel,
        team: team,
        completed: completed ?? this.completed,
        raw: raw,
      );
  factory JobItem.fromMap(Map<String, dynamic> map) => JobItem(
        id: map['id'] ?? _id(),
        title: map['title'] ?? map['task'] ?? map['name'] ?? '',
        area: map['area'] ?? '',
        dayLabel: map['dayLabel'] ?? map['when'] ?? '',
        team: map['team'] ?? map['assignedTo'] ?? '',
        completed: map['completed'] ?? map['done'] ?? false,
        raw: Map<String, dynamic>.from(map),
      );
}

class EmployeeItem {
  final String id;
  final String name;
  final String role;
  final int leaveDays;
  final String phone;
  final Map<String, dynamic> raw;
  EmployeeItem({required this.id, required this.name, required this.role, required this.leaveDays, required this.phone, this.raw = const {}});
  Map<String, dynamic> toMap() => {
        ...raw,
        'id': id,
        'name': name,
        'role': role,
        'leaveDays': leaveDays,
        'phone': phone,
      };
  factory EmployeeItem.fromMap(Map<String, dynamic> map) => EmployeeItem(
        id: map['id'] ?? _id(),
        name: map['name'] ?? '',
        role: map['role'] ?? '',
        leaveDays: (map['leaveDays'] ?? 0) is int ? map['leaveDays'] ?? 0 : int.tryParse('${map['leaveDays']}') ?? 0,
        phone: map['phone'] ?? '',
        raw: Map<String, dynamic>.from(map),
      );
}

class EquipmentItem {
  final String id;
  final String name;
  final EquipmentStatus status;
  final String note;
  final Map<String, dynamic> raw;
  EquipmentItem({required this.id, required this.name, required this.status, required this.note, this.raw = const {}});
  Map<String, dynamic> toMap() => {
        ...raw,
        'id': id,
        'name': name,
        'status': status.name,
        'note': note,
      };
  EquipmentItem copyWith({EquipmentStatus? status, String? note}) => EquipmentItem(
        id: id,
        name: name,
        status: status ?? this.status,
        note: note ?? this.note,
        raw: raw,
      );
  factory EquipmentItem.fromMap(Map<String, dynamic> map) => EquipmentItem(
        id: map['id'] ?? _id(),
        name: map['name'] ?? '',
        status: EquipmentStatus.values.firstWhere(
          (e) => e.name == map['status'],
          orElse: () => EquipmentStatus.ok,
        ),
        note: map['note'] ?? '',
        raw: Map<String, dynamic>.from(map),
      );
}

class UserItem {
  final String id;
  final String displayName;
  final String username;
  final String role;
  final String passwordHash;
  final Map<String, dynamic> raw;
  UserItem({required this.id, required this.displayName, required this.username, required this.role, this.passwordHash = '', this.raw = const {}});
  Map<String, dynamic> toMap() => {
        ...raw,
        'id': id,
        'displayName': displayName,
        'username': username,
        'role': role,
        if (passwordHash.isNotEmpty) 'passwordHash': passwordHash,
      };
  UserItem copyWith({String? passwordHash, String? role}) => UserItem(
        id: id,
        displayName: displayName,
        username: username,
        role: role ?? this.role,
        passwordHash: passwordHash ?? this.passwordHash,
        raw: raw,
      );
  factory UserItem.fromMap(Map<String, dynamic> map) => UserItem(
        id: map['id'] ?? _id(),
        displayName: map['displayName'] ?? map['name'] ?? '',
        username: map['username'] ?? '',
        role: map['role'] ?? 'worker',
        passwordHash: map['passwordHash'] ?? '',
        raw: Map<String, dynamic>.from(map),
      );
}
