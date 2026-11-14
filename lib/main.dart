import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------
// COLOURS: change these three to restyle the whole app
// ---------------------------------------------------------------
const Color kDarkPink = Color(0xFFC2185B); // main dark pink
const Color kLightPink = Color(0xFFFCE4EC); // pink background
const Color kGlowPink = Color(0xFFF48FB1); // glow around the SOS button

// One shared audio player for the fake call ringtone.
// It is "unlocked" by a silent sound when you tap Start, because
// browsers only allow sound after a tap.
final AudioPlayer ringPlayer = AudioPlayer();

// Lets the journey timer open the SOS screen from anywhere in the app.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Default messages (the user can change them in Settings).
const String kDefaultAlert = 'EMERGENCY! I need help. My current location:';
const String kDefaultSafe =
    "I'm safe now. Sorry for the scare, no need to worry.";

String formatDuration(int totalSeconds) {
  final h = totalSeconds ~/ 3600;
  final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

// Opens Google Maps with a search such as "police station near me".
Future<bool> openMapsSearch(String query) {
  final uri = Uri.https(
    'www.google.com',
    '/maps/search/',
    {'api': '1', 'query': query},
  );
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

void main() => runApp(const SafetyApp());

// ---------------------------------------------------------------
// SETTINGS: change this to your country's emergency number
// ---------------------------------------------------------------
const String emergencyNumber = '112';

// ---------------------------------------------------------------
// HELPERS: open the phone's SMS app / dialer
// ---------------------------------------------------------------
Future<bool> openSms(String phone, String message) {
  final uri = Uri(
    scheme: 'sms',
    path: phone,
    query: 'body=${Uri.encodeComponent(message)}',
  );
  return launchUrl(uri);
}

Future<bool> openCall(String phone) {
  return launchUrl(Uri(scheme: 'tel', path: phone));
}

// ---------------------------------------------------------------
// DATA: a contact and how we save it on the phone
// ---------------------------------------------------------------
class Contact {
  final String name;
  final String phone;
  Contact(this.name, this.phone);

  Map<String, String> toJson() => {'name': name, 'phone': phone};

  factory Contact.fromJson(Map<String, dynamic> json) =>
      Contact(json['name'], json['phone']);
}

class ContactStorage {
  static const _key = 'contacts';

  static Future<List<Contact>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw.map((e) => Contact.fromJson(jsonDecode(e))).toList();
  }

  static Future<void> save(List<Contact> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      contacts.map((c) => jsonEncode(c.toJson())).toList(),
    );
  }
}

// ---------------------------------------------------------------
// LOCATION: ask permission and get the current position
// ---------------------------------------------------------------
class LocationService {
  static Future<Position> getCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw 'Location services are turned off.';
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw 'Location permission was denied.';
    }
    if (permission == LocationPermission.deniedForever) {
      throw 'Location permission is blocked. Please enable it in settings.';
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
  }

  static String mapsLink(Position p) =>
      'https://www.google.com/maps?q=${p.latitude},${p.longitude}';
}

// ---------------------------------------------------------------
// SETTINGS: custom SOS message and "I'm safe" message
// ---------------------------------------------------------------
class AppSettings {
  final String alert;
  final String safe;
  AppSettings(this.alert, this.safe);
}

class SettingsStorage {
  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      prefs.getString('alert_message') ?? kDefaultAlert,
      prefs.getString('safe_message') ?? kDefaultSafe,
    );
  }

  static Future<void> save(String alert, String safe) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('alert_message', alert);
    await prefs.setString('safe_message', safe);
  }
}

// ---------------------------------------------------------------
// SAFE JOURNEY TIMER: starts an SOS if the user does not check in.
// It only runs while the app is open.
// ---------------------------------------------------------------
class JourneyTimer {
  // null = no journey running, otherwise the seconds left
  static final ValueNotifier<int?> secondsLeft = ValueNotifier<int?>(null);
  static Timer? _timer;
  static DateTime? _end;

  static void start(int seconds) {
    cancel();
    _end = DateTime.now().add(Duration(seconds: seconds));
    secondsLeft.value = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _end;
      if (end == null) return;
      final ms = end.difference(DateTime.now()).inMilliseconds;
      final left = (ms / 1000).ceil();
      if (left <= 0) {
        cancel();
        _expired();
      } else {
        secondsLeft.value = left;
      }
    });
  }

  static void cancel() {
    _timer?.cancel();
    _timer = null;
    _end = null;
    secondsLeft.value = null;
  }

  static Future<void> _expired() async {
    final contacts = await ContactStorage.load();
    final navigator = navigatorKey.currentState;
    if (navigator == null || contacts.isEmpty) return;
    navigator.push(
      MaterialPageRoute(builder: (_) => SosScreen(contacts: contacts)),
    );
  }
}

// ---------------------------------------------------------------
// APP
// ---------------------------------------------------------------
class SafetyApp extends StatelessWidget {
  const SafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Safety App',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: kDarkPink,
        useMaterial3: true,
        scaffoldBackgroundColor: kLightPink,
        appBarTheme: const AppBarTheme(
          backgroundColor: kLightPink,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------
// HOME SCREEN: SOS button + emergency call + fake call
// ---------------------------------------------------------------
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _startSos(BuildContext context) async {
    final contacts = await ContactStorage.load();
    if (!context.mounted) return;

    if (contacts.isEmpty) {
      _showMessage(context, 'Add at least one trusted contact first');
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ContactsScreen()),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SosScreen(contacts: contacts)),
    );
  }

  Future<void> _callEmergency(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Call emergency?'),
        content: Text('This will dial $emergencyNumber.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Call'),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    final ok = await openCall(emergencyNumber);
    if (!ok && context.mounted) {
      _showMessage(context, 'Could not open the dialer on this device');
    }
  }

  Future<void> _startFakeCall(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;

    final nameController = TextEditingController(
      text: prefs.getString('fake_caller') ?? 'Mom',
    );
    int delay = 0;

    final start = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Fake call'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Caller name'),
              ),
              const SizedBox(height: 16),
              const Text('Ring after'),
              const SizedBox(height: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Now')),
                  ButtonSegment(value: 10, label: Text('10 s')),
                  ButtonSegment(value: 30, label: Text('30 s')),
                ],
                selected: {delay},
                onSelectionChanged: (s) => setLocal(() => delay = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                ringPlayer.play(AssetSource('silence.wav')).catchError((_) {});
                Navigator.pop(ctx, true);
              },
              child: const Text('Start'),
            ),
          ],
        ),
      ),
    );

    if (start != true || !context.mounted) return;

    final typed = nameController.text.trim();
    final name = typed.isEmpty ? 'Mom' : typed;
    await prefs.setString('fake_caller', name);
    if (!context.mounted) return;

    final navigator = Navigator.of(context);
    if (delay > 0) {
      _showMessage(context, 'Fake call will ring in $delay seconds');
      await Future.delayed(Duration(seconds: delay));
    }

    navigator.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FakeCallScreen(callerName: name),
      ),
    );
  }

  Future<void> _openImSafe(BuildContext context) async {
    final contacts = await ContactStorage.load();
    final settings = await SettingsStorage.load();
    if (!context.mounted) return;

    if (contacts.isEmpty) {
      _showMessage(context, 'Add at least one trusted contact first');
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SendMessageScreen(
          title: "I'm Safe",
          message: settings.safe,
          contacts: contacts,
        ),
      ),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      width: 150,
      height: 48,
      child: FilledButton.tonalIcon(
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        label: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety App'),
        actions: [
          IconButton(
            tooltip: 'Message settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Trusted contacts',
            icon: const Icon(Icons.people),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ContactsScreen()),
            ),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ValueListenableBuilder<int?>(
                valueListenable: JourneyTimer.secondsLeft,
                builder: (context, left, _) {
                  if (left == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: ActionChip(
                      avatar: const Icon(Icons.timer, size: 18),
                      label: Text(
                        'Safe journey active: ${formatDuration(left)} left',
                      ),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const JourneyScreen(),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const Text(
                'In danger? Press SOS',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 28),
              GestureDetector(
                onTap: () => _startSos(context),
                child: Container(
                  width: 220,
                  height: 220,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: kDarkPink,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: kGlowPink,
                        blurRadius: 30,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: const Text(
                    'SOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: 240,
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => _callEmergency(context),
                  icon: const Icon(Icons.call),
                  label: const Text('Call Emergency'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: 240,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: () => _startFakeCall(context),
                  icon: const Icon(Icons.phone_in_talk),
                  label: const Text('Fake Call'),
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  _tile(
                    Icons.local_police,
                    'Nearby Help',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NearbyHelpScreen(),
                      ),
                    ),
                  ),
                  _tile(
                    Icons.timer,
                    'Safe Journey',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const JourneyScreen()),
                    ),
                  ),
                  _tile(
                    Icons.support_agent,
                    'Helplines',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const HelplinesScreen(),
                      ),
                    ),
                  ),
                  _tile(
                    Icons.verified_user,
                    "I'm Safe",
                    () => _openImSafe(context),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'This app supports, but does not replace, calling '
                  'emergency services.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// FAKE CALL SCREEN: looks like an incoming call, then an active call
// ---------------------------------------------------------------
class FakeCallScreen extends StatefulWidget {
  final String callerName;
  const FakeCallScreen({super.key, required this.callerName});

  @override
  State<FakeCallScreen> createState() => _FakeCallScreenState();
}

class _FakeCallScreenState extends State<FakeCallScreen> {
  bool _answered = false;
  int _seconds = 0;
  Timer? _callTimer;
  Timer? _ringTimer;

  Future<void> _startRinging() async {
    if (_answered) return;
    try {
      await ringPlayer.stop();
      await ringPlayer.setReleaseMode(ReleaseMode.loop);
      await ringPlayer.play(AssetSource('ringtone.wav'));
    } catch (_) {
      // Sound blocked by the browser: tapping the screen tries again.
    }
  }

  Future<void> _stopRinging() async {
    try {
      await ringPlayer.stop();
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _ringTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => HapticFeedback.heavyImpact(),
    );
    _startRinging();
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    _ringTimer?.cancel();
    _stopRinging();
    super.dispose();
  }

  void _answer() {
    _ringTimer?.cancel();
    _stopRinging();
    setState(() => _answered = true);
    _callTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _seconds++),
    );
  }

  void _end() => Navigator.pop(context);

  String _format(int total) {
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _roundButton({
    required Color color,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onPressed,
          child: CircleAvatar(
            radius: 36,
            backgroundColor: color,
            child: Icon(icon, color: Colors.white, size: 34),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.callerName.isEmpty
        ? '?'
        : widget.callerName[0].toUpperCase();

    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!_answered && ringPlayer.state != PlayerState.playing) {
            _startRinging();
          }
        },
        child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 64),
            Text(
              _answered ? _format(_seconds) : 'mobile',
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 12),
            Text(
              widget.callerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 32),
            CircleAvatar(
              radius: 56,
              backgroundColor: Colors.grey.shade700,
              child: Text(
                initial,
                style: const TextStyle(color: Colors.white, fontSize: 48),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 64),
              child: _answered
                  ? _roundButton(
                      color: Colors.red,
                      icon: Icons.call_end,
                      label: 'End',
                      onPressed: _end,
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _roundButton(
                          color: Colors.red,
                          icon: Icons.call_end,
                          label: 'Decline',
                          onPressed: _end,
                        ),
                        _roundButton(
                          color: Colors.green,
                          icon: Icons.call,
                          label: 'Accept',
                          onPressed: _answer,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// SOS SCREEN: countdown -> location -> message -> send SMS
// ---------------------------------------------------------------
enum SosStage { countdown, locating, ready, error }

class SosScreen extends StatefulWidget {
  final List<Contact> contacts;
  const SosScreen({super.key, required this.contacts});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  int _secondsLeft = 5;
  Timer? _timer;
  SosStage _stage = SosStage.countdown;
  String _message = '';
  String _link = '';
  String _error = '';
  final Set<String> _sent = {};
  String _safeText = kDefaultSafe;
  bool _showSafe = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft <= 1) {
        t.cancel();
        _prepareAlert();
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  Future<void> _prepareAlert() async {
    setState(() => _stage = SosStage.locating);
    try {
      final position = await LocationService.getCurrentLocation();
      final settings = await SettingsStorage.load();
      if (!mounted) return;
      final link = LocationService.mapsLink(position);
      setState(() {
        _link = link;
        _message = '${settings.alert} $link';
        _safeText = settings.safe;
        _stage = SosStage.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _stage = SosStage.error;
      });
    }
  }

  String _sentKey(Contact c) => '${_showSafe ? 's' : 'a'}:${c.phone}';

  Future<void> _openMap() async {
    await launchUrl(Uri.parse(_link), mode: LaunchMode.externalApplication);
  }

  Future<void> _sendSms(Contact contact) async {
    final text = _showSafe ? _safeText : _message;
    final ok = await openSms(contact.phone, text);
    if (!mounted) return;
    if (ok) {
      setState(() => _sent.add(_sentKey(contact)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the SMS app on this device'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS Alert')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    switch (_stage) {
      case SosStage.countdown:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Sending alert in', style: TextStyle(fontSize: 22)),
            const SizedBox(height: 16),
            Text(
              '$_secondsLeft',
              style: const TextStyle(
                fontSize: 96,
                fontWeight: FontWeight.bold,
                color: kDarkPink,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 220,
              height: 56,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('CANCEL', style: TextStyle(fontSize: 20)),
              ),
            ),
          ],
        );

      case SosStage.locating:
        return const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 24),
            Text('Getting your location...', style: TextStyle(fontSize: 18)),
          ],
        );

      case SosStage.ready:
        return SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 64),
              const SizedBox(height: 8),
              const Text(
                'Alert ready',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('SOS alert'),
                    selected: !_showSafe,
                    onSelected: (_) => setState(() => _showSafe = false),
                  ),
                  ChoiceChip(
                    label: const Text("I'm safe"),
                    selected: _showSafe,
                    onSelected: (_) => setState(() => _showSafe = true),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(_showSafe ? _safeText : _message),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tap Send for each contact. Your SMS app opens with the '
                'message ready, then press send there.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ...widget.contacts.map((c) {
                final sent = _sent.contains(_sentKey(c));
                return ListTile(
                  leading: Icon(
                    sent ? Icons.check_circle : Icons.person,
                    color: sent ? Colors.green : null,
                  ),
                  title: Text(c.name),
                  subtitle: Text(c.phone),
                  trailing: FilledButton(
                    onPressed: () => _sendSms(c),
                    child: Text(sent ? 'Resend' : 'Send SMS'),
                  ),
                );
              }),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openMap,
                icon: const Icon(Icons.map),
                label: const Text('Open location in Maps'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        );

      case SosStage.error:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: kDarkPink, size: 72),
            const SizedBox(height: 12),
            Text(_error, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _prepareAlert,
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back'),
            ),
          ],
        );
    }
  }
}

// ---------------------------------------------------------------
// NEARBY HELP: opens Google Maps searches near the user
// ---------------------------------------------------------------
class NearbyHelpScreen extends StatelessWidget {
  const NearbyHelpScreen({super.key});

  static const _places = [
    ('Police stations', 'police station near me', Icons.local_police),
    ('Hospitals', 'hospital near me', Icons.local_hospital),
    ('Pharmacies', 'pharmacy near me', Icons.local_pharmacy),
  ];

  Future<void> _open(BuildContext context, String query) async {
    final ok = await openMapsSearch(query);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Maps on this device')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby Help')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Opens Google Maps with results near your current location. '
            'Allow location if Maps asks.',
          ),
          const SizedBox(height: 12),
          ..._places.map(
            (p) => Card(
              child: ListTile(
                leading: Icon(p.$3, color: kDarkPink),
                title: Text(p.$1),
                subtitle: const Text('Tap to open in Maps'),
                trailing: const Icon(Icons.open_in_new),
                onTap: () => _open(context, p.$2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------
// HELPLINES: tap to open the dialer (numbers for India)
// ---------------------------------------------------------------
class HelplinesScreen extends StatelessWidget {
  const HelplinesScreen({super.key});

  static const _helplines = [
    ('112', 'National Emergency Number',
        'Police, fire, ambulance, women and child emergencies'),
    ('100', 'Police', 'Still active in most states alongside 112'),
    ('181', 'Women Helpline', 'Women in distress, domestic violence support'),
    ('1091', 'Women in Distress', 'Police women helpline, works in some states'),
    ('102', 'Ambulance', 'National ambulance service (108 in many states)'),
    ('1098', 'Child Helpline', 'Children in need of care and protection'),
    ('1930', 'Cyber Crime Helpline', 'Report online fraud or cyber crime'),
  ];

  Future<void> _call(BuildContext context, String number) async {
    final ok = await openCall(number);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the dialer here')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Helplines')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Numbers for India. Availability can vary by state. '
            'Tap a number to open the dialer.',
          ),
          const SizedBox(height: 12),
          ..._helplines.map(
            (h) => Card(
              child: ListTile(
                leading: const Icon(Icons.support_agent, color: kDarkPink),
                title: Text('${h.$1}  ${h.$2}'),
                subtitle: Text(h.$3),
                trailing: const Icon(Icons.call),
                onTap: () => _call(context, h.$1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------
// SETTINGS: edit the SOS message and the "I'm safe" message
// ---------------------------------------------------------------
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _alertController = TextEditingController();
  final _safeController = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _alertController.dispose();
    _safeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await SettingsStorage.load();
    if (!mounted) return;
    setState(() {
      _alertController.text = s.alert;
      _safeController.text = s.safe;
      _loading = false;
    });
  }

  void _reset() {
    setState(() {
      _alertController.text = kDefaultAlert;
      _safeController.text = kDefaultSafe;
    });
  }

  Future<void> _save() async {
    final alert = _alertController.text.trim();
    final safe = _safeController.text.trim();
    await SettingsStorage.save(
      alert.isEmpty ? kDefaultAlert : alert,
      safe.isEmpty ? kDefaultSafe : safe,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Messages saved')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Message Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'SOS message',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _alertController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    helperText:
                        'Your location link is added automatically after this text.',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "I'm safe message",
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _safeController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _reset,
                        child: const Text('Reset'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _save,
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------
// SEND MESSAGE: send one message to each trusted contact
// ---------------------------------------------------------------
class SendMessageScreen extends StatefulWidget {
  final String title;
  final String message;
  final List<Contact> contacts;
  const SendMessageScreen({
    super.key,
    required this.title,
    required this.message,
    required this.contacts,
  });

  @override
  State<SendMessageScreen> createState() => _SendMessageScreenState();
}

class _SendMessageScreenState extends State<SendMessageScreen> {
  final Set<String> _sent = {};

  Future<void> _send(Contact contact) async {
    final ok = await openSms(contact.phone, widget.message);
    if (!mounted) return;
    if (ok) {
      setState(() => _sent.add(contact.phone));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the SMS app on this device'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(widget.message),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Tap Send for each contact. Your SMS app opens with the '
            'message ready, then press send there.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          ...widget.contacts.map((c) {
            final sent = _sent.contains(c.phone);
            return ListTile(
              leading: Icon(
                sent ? Icons.check_circle : Icons.person,
                color: sent ? Colors.green : null,
              ),
              title: Text(c.name),
              subtitle: Text(c.phone),
              trailing: FilledButton(
                onPressed: () => _send(c),
                child: Text(sent ? 'Resend' : 'Send SMS'),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------
// SAFE JOURNEY: auto SOS if the user does not check in in time
// ---------------------------------------------------------------
class JourneyScreen extends StatefulWidget {
  const JourneyScreen({super.key});

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  static const _options = [1, 15, 30, 60];
  int _minutes = 15;

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _start() async {
    final contacts = await ContactStorage.load();
    if (!mounted) return;
    if (contacts.isEmpty) {
      _showMessage('Add at least one trusted contact first');
      return;
    }
    JourneyTimer.start(_minutes * 60);
    _showMessage('Safe journey started');
  }

  void _end() {
    JourneyTimer.cancel();
    _showMessage('Journey ended. Glad you are safe!');
  }

  Widget _setup() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Choose how long your trip will take. If you do not tap '
          '"I\'m safe" before time runs out, an SOS alert starts '
          'automatically, with a 5-second cancel countdown.',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 12),
        const Text(
          'Keep the app open: the timer only runs while the app is open.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _options
              .map(
                (m) => ChoiceChip(
                  label: Text(m == 1 ? '1 min (demo)' : '$m min'),
                  selected: _minutes == m,
                  onSelected: (_) => setState(() => _minutes = m),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 32),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start journey'),
          ),
        ),
      ],
    );
  }

  Widget _active(int left) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Time left', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 12),
            Text(
              formatDuration(left),
              style: const TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: kDarkPink,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'If this reaches zero, an SOS alert starts.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 260,
              height: 56,
              child: FilledButton.icon(
                onPressed: _end,
                icon: const Icon(Icons.verified_user),
                label: const Text("I'm safe, end journey"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safe Journey')),
      body: ValueListenableBuilder<int?>(
        valueListenable: JourneyTimer.secondsLeft,
        builder: (context, left, _) =>
            left == null ? _setup() : _active(left),
      ),
    );
  }
}

// ---------------------------------------------------------------
// CONTACTS SCREEN: add, view, delete trusted contacts
// ---------------------------------------------------------------
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<Contact> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final saved = await ContactStorage.load();
    if (!mounted) return;
    setState(() {
      _contacts = saved;
      _loading = false;
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _addContact() async {
    if (_contacts.length >= 5) {
      _showMessage('You can save up to 5 contacts');
      return;
    }

    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add trusted contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;

    final name = nameController.text.trim();
    final phone = phoneController.text.trim();

    if (name.isEmpty || phone.length < 10) {
      _showMessage('Enter a name and a phone number of at least 10 digits');
      return;
    }

    setState(() => _contacts.add(Contact(name, phone)));
    await ContactStorage.save(_contacts);
  }

  Future<void> _deleteContact(int index) async {
    setState(() => _contacts.removeAt(index));
    await ContactStorage.save(_contacts);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Trusted Contacts (${_contacts.length}/5)'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContact,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No contacts yet.\nTap + to add someone who should get your SOS alert.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _contacts.length,
                  itemBuilder: (context, index) {
                    final c = _contacts[index];
                    return ListTile(
                      leading: CircleAvatar(
                        child: Text(c.name[0].toUpperCase()),
                      ),
                      title: Text(c.name),
                      subtitle: Text(c.phone),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: kDarkPink),
                        onPressed: () => _deleteContact(index),
                      ),
                    );
                  },
                ),
    );
  }
}