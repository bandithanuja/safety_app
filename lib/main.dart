import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------
// THEMES: colours come from the theme chosen in Settings
// ---------------------------------------------------------------
class AppTheme {
  final String name;
  final Color primary; // strong colour (SOS button, icons)
  final Color background; // soft background colour
  final Color glow; // glow around the SOS button
  const AppTheme(this.name, this.primary, this.background, this.glow);
}

const List<AppTheme> kThemes = [
  AppTheme(
    'Rose pink',
    Color(0xFFC2185B),
    Color(0xFFFCE4EC),
    Color(0xFFF48FB1),
  ),
  AppTheme(
    'Lavender',
    Color(0xFF7B1FA2),
    Color(0xFFF3E5F5),
    Color(0xFFCE93D8),
  ),
  AppTheme(
    'Teal',
    Color(0xFF00796B),
    Color(0xFFE0F2F1),
    Color(0xFF80CBC4),
  ),
];

// The theme currently in use (changing it rebuilds the whole app).
final ValueNotifier<int> themeIndex = ValueNotifier<int>(0);

Color get kDarkPink => kThemes[themeIndex.value].primary;
Color get kLightPink => kThemes[themeIndex.value].background;
Color get kGlowPink => kThemes[themeIndex.value].glow;

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getInt('theme_index') ?? 0;
  themeIndex.value = (saved >= 0 && saved < kThemes.length) ? saved : 0;
  final seenWelcome = prefs.getBool('seen_welcome') ?? false;
  runApp(SafetyApp(showWelcome: !seenWelcome));
}

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
  // Seconds until the expected arrival (null = no journey running).
  static final ValueNotifier<int?> secondsLeft = ValueNotifier<int?>(null);
  // Seconds left to answer the reminder (null = no reminder showing).
  static final ValueNotifier<int?> graceLeft = ValueNotifier<int?>(null);

  static Timer? _timer;
  static Timer? _graceTimer;
  static DateTime? _end;
  static DateTime? _graceEnd;
  static bool _notifyContacts = true;
  static int _graceSeconds = 120;

  static bool get notifyContacts => _notifyContacts;

  static int _secondsUntil(DateTime end) =>
      (end.difference(DateTime.now()).inMilliseconds / 1000).ceil();

  static void start(
    int seconds, {
    int graceSeconds = 120,
    bool notifyContacts = true,
  }) {
    cancel();
    _graceSeconds = graceSeconds;
    _notifyContacts = notifyContacts;
    _end = DateTime.now().add(Duration(seconds: seconds));
    secondsLeft.value = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _end;
      if (end == null) return;
      final left = _secondsUntil(end);
      if (left <= 0) {
        _timer?.cancel();
        _timer = null;
        _end = null;
        secondsLeft.value = null;
        _askForCheckIn();
      } else {
        secondsLeft.value = left;
      }
    });
  }

  // Stops everything: the journey, the reminder and the alarm sound.
  static void cancel() {
    _timer?.cancel();
    _timer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _end = null;
    _graceEnd = null;
    secondsLeft.value = null;
    graceLeft.value = null;
    _stopAlarm();
  }

  static Future<void> _stopAlarm() async {
    try {
      await ringPlayer.stop();
    } catch (_) {}
  }

  static Future<void> _playAlarm() async {
    try {
      await ringPlayer.stop();
      await ringPlayer.setReleaseMode(ReleaseMode.loop);
      await ringPlayer.play(AssetSource('ringtone.wav'));
    } catch (_) {
      // Sound can be blocked by the browser. The screen still shows.
    }
  }

  // Expected arrival time reached: remind the user to check in.
  static void _askForCheckIn() {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    _graceEnd = DateTime.now().add(Duration(seconds: _graceSeconds));
    graceLeft.value = _graceSeconds;
    _playAlarm();
    HapticFeedback.heavyImpact();
    _graceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _graceEnd;
      if (end == null) return;
      final left = _secondsUntil(end);
      if (left <= 0) {
        _graceExpired();
      } else {
        graceLeft.value = left;
      }
    });
    navigator.push(
      MaterialPageRoute(builder: (_) => const ArrivalCheckScreen()),
    );
  }

  // No answer to the reminder: start the SOS flow if the user chose that.
  static Future<void> _graceExpired() async {
    final notify = _notifyContacts;
    cancel();
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    if (notify) {
      final contacts = await ContactStorage.load();
      if (contacts.isNotEmpty) {
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => SosScreen(contacts: contacts)),
        );
        return;
      }
    }
    navigator.pop();
  }

  // The user pressed "I need help" on the reminder screen.
  static Future<void> needHelp() async {
    cancel();
    final contacts = await ContactStorage.load();
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    if (contacts.isEmpty) {
      navigator.pop();
      return;
    }
    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => SosScreen(contacts: contacts)),
    );
  }
}

// ---------------------------------------------------------------
// APP
// ---------------------------------------------------------------
class SafetyApp extends StatelessWidget {
  final bool showWelcome;
  const SafetyApp({super.key, this.showWelcome = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: themeIndex,
      builder: (context, value, child) {
        final t = kThemes[value];
        return MaterialApp(
          title: 'Saheli Safe',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: t.primary,
            useMaterial3: true,
            scaffoldBackgroundColor: t.background,
            appBarTheme: AppBarTheme(
              backgroundColor: t.background,
              surfaceTintColor: Colors.transparent,
            ),
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
                TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
                TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
                TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
                TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
                TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
              },
            ),
          ),
          home: showWelcome ? const WelcomeScreen() : const HomeScreen(),
        );
      },
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

  Widget _card(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.white,
      elevation: 1,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: kLightPink,
                child: Icon(icon, color: kDarkPink),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    void go(Widget screen) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saheli Safe'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => go(const SettingsScreen()),
          ),
          IconButton(
            tooltip: 'Trusted contacts',
            icon: const Icon(Icons.people),
            onPressed: () => go(const ContactsScreen()),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kLightPink, Colors.white],
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                children: [
                  ValueListenableBuilder<int?>(
                    valueListenable: JourneyTimer.secondsLeft,
                    builder: (context, left, _) {
                      if (left == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: ActionChip(
                          avatar: const Icon(Icons.timer, size: 18),
                          label: Text(
                            'Arrival check active: ${formatDuration(left)} left',
                          ),
                          onPressed: () => go(const JourneyScreen()),
                        ),
                      );
                    },
                  ),
                  const Text(
                    'In danger? Press SOS',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  PulsingSosButton(onTap: () => _startSos(context)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: () => _callEmergency(context),
                            icon: const Icon(Icons.call),
                            label: const Text('Call Emergency'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: OutlinedButton.icon(
                            onPressed: () => _startFakeCall(context),
                            icon: const Icon(Icons.phone_in_talk),
                            label: const Text('Fake Call'),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.95,
                    children: [
                      _card(
                        context,
                        Icons.local_police,
                        'Nearby Help',
                        () => go(const NearbyHelpScreen()),
                      ),
                      _card(
                        context,
                        Icons.timer,
                        'Arrival Check',
                        () => go(const JourneyScreen()),
                      ),
                      _card(
                        context,
                        Icons.support_agent,
                        'Helplines',
                        () => go(const HelplinesScreen()),
                      ),
                      _card(
                        context,
                        Icons.chat_bubble,
                        'Assistant',
                        () => go(const SafetyAssistantScreen()),
                      ),
                      _card(
                        context,
                        Icons.verified_user,
                        "I'm Safe",
                        () => _openImSafe(context),
                      ),
                      _card(
                        context,
                        Icons.people,
                        'Contacts',
                        () => go(const ContactsScreen()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'This app supports, but does not replace, calling '
                      'emergency services.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// PULSING SOS BUTTON: the main button, with a gentle animated ring
// ---------------------------------------------------------------
class PulsingSosButton extends StatefulWidget {
  final VoidCallback onTap;
  const PulsingSosButton({super.key, required this.onTap});

  @override
  State<PulsingSosButton> createState() => _PulsingSosButtonState();
}

class _PulsingSosButtonState extends State<PulsingSosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'SOS emergency button',
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_controller.value);
            return SizedBox(
              width: 260,
              height: 260,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 200 + 60 * t,
                    height: 200 + 60 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kGlowPink.withAlpha((110 * (1 - t)).round()),
                    ),
                  ),
                  Container(
                    width: 200 + 8 * t,
                    height: 200 + 8 * t,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kDarkPink,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: kGlowPink,
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Text(
                      'SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 52,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
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
            SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: _secondsLeft / 5.0),
                      duration: const Duration(milliseconds: 900),
                      builder: (context, value, _) =>
                          CircularProgressIndicator(
                        value: value,
                        strokeWidth: 12,
                        color: kDarkPink,
                        backgroundColor: kGlowPink.withAlpha(90),
                      ),
                    ),
                  ),
                  Text(
                    '$_secondsLeft',
                    style: TextStyle(
                      fontSize: 80,
                      fontWeight: FontWeight.bold,
                      color: kDarkPink,
                    ),
                  ),
                ],
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
            Icon(Icons.error_outline, color: kDarkPink, size: 72),
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
                leading: Icon(Icons.support_agent, color: kDarkPink),
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

  Future<void> _setTheme(int i) async {
    themeIndex.value = i;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('theme_index', i);
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
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Theme',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<int>(
                  valueListenable: themeIndex,
                  builder: (context, selected, _) => Wrap(
                    spacing: 20,
                    children: [
                      for (int i = 0; i < kThemes.length; i++)
                        GestureDetector(
                          onTap: () => _setTheme(i),
                          child: Column(
                            children: [
                              CircleAvatar(
                                radius: 26,
                                backgroundColor: kThemes[i].primary,
                                child: selected == i
                                    ? const Icon(Icons.check,
                                        color: Colors.white)
                                    : null,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                kThemes[i].name,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const WelcomeScreen(fromSettings: true),
                    ),
                  ),
                  icon: const Icon(Icons.slideshow),
                  label: const Text('Show welcome screens again'),
                ),
                const SizedBox(height: 24),
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
// SMART ARRIVAL CHECK: reminder first, then an SOS if no check-in
// ---------------------------------------------------------------
class JourneyScreen extends StatefulWidget {
  const JourneyScreen({super.key});

  @override
  State<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends State<JourneyScreen> {
  static const _durations = [1, 15, 30, 60];
  static const _graceOptions = [1, 2, 5];

  int _minutes = 15;
  TimeOfDay? _arrival;
  int _graceMinutes = 2;
  bool _notify = true;

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  int _secondsUntil(TimeOfDay t) {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target.difference(now).inSeconds;
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (t == null || !mounted) return;
    setState(() => _arrival = t);
  }

  Future<void> _start() async {
    // Unlock sound while the user's tap is still fresh (browser rule),
    // so the reminder alarm can play later.
    ringPlayer.play(AssetSource('silence.wav')).catchError((_) {});

    final contacts = await ContactStorage.load();
    if (!mounted) return;
    if (_notify && contacts.isEmpty) {
      _showMessage('Add at least one trusted contact first');
      return;
    }
    final arrival = _arrival;
    final seconds = arrival != null ? _secondsUntil(arrival) : _minutes * 60;
    JourneyTimer.start(
      seconds,
      graceSeconds: _graceMinutes * 60,
      notifyContacts: _notify,
    );
    _showMessage('Arrival check started');
  }

  void _arrived() {
    JourneyTimer.cancel();
    _showMessage('Glad you arrived safely!');
  }

  Widget _setup() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Set when you expect to arrive. If you have not checked in by '
          'then, the app reminds you with a loud alert. If you still do '
          'not respond, it can start an SOS alert for your trusted contacts.',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 8),
        const Text(
          'Keep the app open: it only runs while the app is open, and the '
          'SOS step still needs your tap on Send in the SMS app.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 24),
        const Text(
          'I will arrive in',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _durations
              .map(
                (m) => ChoiceChip(
                  label: Text(m == 1 ? '1 min (demo)' : '$m min'),
                  selected: _arrival == null && _minutes == m,
                  onSelected: (_) => setState(() {
                    _minutes = m;
                    _arrival = null;
                  }),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _pickTime,
          icon: const Icon(Icons.access_time),
          label: Text(
            _arrival == null
                ? 'Or pick an arrival time'
                : 'Arrive at ${_arrival!.format(context)}',
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'If I do not check in, wait this long after the reminder',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: _graceOptions
              .map(
                (m) => ChoiceChip(
                  label: Text('$m min'),
                  selected: _graceMinutes == m,
                  onSelected: (_) => setState(() => _graceMinutes = m),
                ),
              )
              .toList(),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Then alert my trusted contacts'),
          subtitle: const Text('Starts the SOS flow if I do not respond'),
          value: _notify,
          onChanged: (v) => setState(() => _notify = v),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start arrival check'),
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
            const Text(
              'Time until expected arrival',
              style: TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 12),
            Text(
              formatDuration(left),
              style: TextStyle(
                fontSize: 64,
                fontWeight: FontWeight.bold,
                color: kDarkPink,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'When this reaches zero, the app will ask if you arrived safely.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 260,
              height: 56,
              child: FilledButton.icon(
                onPressed: _arrived,
                icon: const Icon(Icons.verified_user),
                label: const Text("I've arrived safely"),
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
      appBar: AppBar(title: const Text('Smart Arrival Check')),
      body: ValueListenableBuilder<int?>(
        valueListenable: JourneyTimer.secondsLeft,
        builder: (context, left, _) =>
            left == null ? _setup() : _active(left),
      ),
    );
  }
}

// ---------------------------------------------------------------
// ARRIVAL REMINDER: "Have you arrived safely?" with a countdown
// ---------------------------------------------------------------
class ArrivalCheckScreen extends StatelessWidget {
  const ArrivalCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Arrival check'),
          automaticallyImplyLeading: false,
        ),
        body: ValueListenableBuilder<int?>(
          valueListenable: JourneyTimer.graceLeft,
          builder: (context, left, _) {
            final consequence = JourneyTimer.notifyContacts
                ? 'Otherwise an alert for your trusted contacts will start.'
                : 'Otherwise this reminder will close.';
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.notifications_active,
                      size: 72,
                      color: kDarkPink,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Have you arrived safely?',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      left == null
                          ? ''
                          : 'Please check in within ${formatDuration(left)}.\n'
                              '$consequence',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: 260,
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: () {
                          JourneyTimer.cancel();
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.verified_user),
                        label: const Text("Yes, I'm safe"),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 260,
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: JourneyTimer.needHelp,
                        icon: const Icon(Icons.sos),
                        label: const Text('I need help'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// SAFETY ASSISTANT: guided, step-by-step help (no AI, no server)
// All guidance is fixed text, so it is predictable and checkable.
// ---------------------------------------------------------------
class _Opt {
  final String label;
  final String? next;
  final String? tel;
  final String? url;
  final bool sos;
  const _Opt(this.label, {this.next, this.tel, this.url, this.sos = false});
}

class _Node {
  final String text;
  final List<_Opt> options;
  const _Node(this.text, this.options);
}

class _Msg {
  final String text;
  final bool fromUser;
  _Msg(this.text, this.fromUser);
}

const String _cyberPortal = 'https://cybercrime.gov.in';

const Map<String, _Node> _assistantNodes = {
  'start': _Node(
    "Hi, I'm the Saheli assistant. I'm sorry if something has happened, "
    "and I'm glad you reached out. I can guide you step by step. This is "
    "general guidance, not legal advice, and procedures can differ by "
    "state.\n\nWhat do you need help with?",
    [
      _Opt("I'm in danger right now", next: 'danger'),
      _Opt('Online harassment or cyber crime', next: 'cyber'),
      _Opt('I want to file a complaint', next: 'complaint'),
      _Opt('How to keep evidence safe', next: 'evidence'),
      _Opt('Helplines and support', next: 'support'),
    ],
  ),
  'danger': _Node(
    "Your safety comes first.\n\n"
    "• If you can, move to a safe, well-lit place with other people.\n"
    "• Call 112 now.\n"
    "• You can also use the SOS button to alert your trusted contacts "
    "with your location.",
    [
      _Opt('Call 112', tel: '112'),
      _Opt('Start SOS alert', sos: true),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'cyber': _Node(
    "I'm sorry you're going through this. It is not your fault. Here is "
    "what you can do:\n\n"
    "1. Do not delete anything yet. Save evidence first.\n"
    "2. Avoid replying to or arguing with the person.\n"
    "3. After saving evidence, block the person and report the account "
    "on the platform.\n"
    "4. Report at the National Cyber Crime Reporting Portal "
    "(cybercrime.gov.in). Choose the Women/Child Related Crime category. "
    "Reports in that category can be made anonymously.\n"
    "5. If money was taken, call 1930 right away.",
    [
      _Opt('Open the cyber crime portal', url: _cyberPortal),
      _Opt('Call 1930', tel: '1930'),
      _Opt('How to keep evidence safe', next: 'evidence'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'complaint': _Node(
    "You can file a complaint in more than one way. Which would you like "
    "to know about?",
    [
      _Opt('At a police station (FIR)', next: 'fir'),
      _Opt('Zero FIR (any police station)', next: 'zero'),
      _Opt('Online', next: 'online'),
      _Opt('The police refused my complaint', next: 'refused'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'fir': _Node(
    "To file an FIR at a police station:\n\n"
    "1. Go to the station and tell the officer what happened. For a "
    "serious (cognizable) offence, police are expected to register an "
    "FIR.\n"
    "2. Take someone you trust with you if you can.\n"
    "3. Read what is written down and sign only when you are satisfied "
    "it is correct.\n"
    "4. Ask for a free copy of the FIR. This is your right.\n"
    "5. Note the FIR number, the date, and the police station.",
    [
      _Opt('Zero FIR', next: 'zero'),
      _Opt('The police refused', next: 'refused'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'zero': _Node(
    "A Zero FIR can be filed at any police station, no matter where the "
    "incident happened, for serious (cognizable) offences. That station "
    "records it and then transfers it to the right police station.\n\n"
    "Ask for a free copy and note the number.",
    [
      _Opt('The police refused', next: 'refused'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'online': _Node(
    "• Cyber crimes: use cybercrime.gov.in. Women/Child Related Crime "
    "reports can be anonymous.\n"
    "• Some states also allow an e-FIR through the state police website. "
    "An e-FIR must be signed within 3 days for it to be valid.\n"
    "• Filing on the cyber crime portal and calling 1930 is free. Anyone "
    "who asks you for money to file a complaint may be a scammer.",
    [
      _Opt('Open the cyber crime portal', url: _cyberPortal),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'refused': _Node(
    "Police generally cannot refuse to register an FIR for a serious "
    "(cognizable) offence. If they refuse:\n\n"
    "1. Send the substance of your complaint in writing to the "
    "Superintendent of Police (SP). The law for this is Section 173(4) "
    "of the BNSS.\n"
    "2. You can also approach a Magistrate.\n"
    "3. Keep a copy of everything you send, and note the date.\n\n"
    "A lawyer can help you with the next step.",
    [
      _Opt('Helplines and support', next: 'support'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'evidence': _Node(
    "Evidence can matter later, so keep it safe:\n\n"
    "• Take screenshots that show the date, time, username, and the full "
    "conversation. Do not crop them.\n"
    "• Save profile links, usernames, phone numbers, and email "
    "addresses.\n"
    "• Keep original messages, voice notes, photos, and call logs. Do "
    "not edit or delete them.\n"
    "• Back up copies somewhere safe, such as another device.\n"
    "• Write down what happened, with dates and times, while you "
    "remember it.\n"
    "• If you were physically hurt, get medical care first. A doctor's "
    "record can also document injuries.",
    [
      _Opt('Report online', next: 'online'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
  'support': _Node(
    "You are not alone. These services can help (India):\n\n"
    "• 112: emergency\n"
    "• 181: Women Helpline\n"
    "• 1091: Women in Distress (works in some states)\n"
    "• 1930: Cyber Crime Helpline\n"
    "• 1098: Child Helpline\n\n"
    "The National Commission for Women also accepts complaints from "
    "women.",
    [
      _Opt('Call 112', tel: '112'),
      _Opt('Call 181', tel: '181'),
      _Opt('Call 1930', tel: '1930'),
      _Opt('Back to start', next: 'start'),
    ],
  ),
};

class SafetyAssistantScreen extends StatefulWidget {
  const SafetyAssistantScreen({super.key});

  @override
  State<SafetyAssistantScreen> createState() => _SafetyAssistantScreenState();
}

class _SafetyAssistantScreenState extends State<SafetyAssistantScreen> {
  final ScrollController _scroll = ScrollController();
  final List<_Msg> _messages = [];
  late _Node _current;

  @override
  void initState() {
    super.initState();
    _current = _assistantNodes['start']!;
    _messages.add(_Msg(_current.text, false));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _startSos() async {
    final contacts = await ContactStorage.load();
    if (!mounted) return;
    if (contacts.isEmpty) {
      _showMessage('Add at least one trusted contact first');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SosScreen(contacts: contacts)),
    );
  }

  Future<void> _choose(_Opt opt) async {
    setState(() => _messages.add(_Msg(opt.label, true)));
    _scrollToEnd();

    final next = opt.next;
    if (next != null) {
      final node = _assistantNodes[next]!;
      setState(() {
        _current = node;
        _messages.add(_Msg(node.text, false));
      });
      _scrollToEnd();
    } else if (opt.tel != null) {
      final ok = await openCall(opt.tel!);
      if (!ok && mounted) _showMessage('Could not open the dialer here');
    } else if (opt.url != null) {
      final ok = await launchUrl(
        Uri.parse(opt.url!),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) _showMessage('Could not open the link here');
    } else if (opt.sos) {
      await _startSos();
    }
  }

  Widget _bubble(_Msg m) {
    final maxWidth = MediaQuery.of(context).size.width * 0.82;
    return Align(
      alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: m.fromUser ? kDarkPink : Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          m.text,
          style: TextStyle(
            color: m.fromUser ? Colors.white : Colors.black87,
            fontSize: 15,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety Assistant')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, i) => _bubble(_messages[i]),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _current.options
                    .map(
                      (o) => ActionChip(
                        label: Text(o.label),
                        onPressed: () => _choose(o),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------
// WELCOME SCREENS: short first-time introduction
// ---------------------------------------------------------------
class WelcomeScreen extends StatefulWidget {
  final bool fromSettings;
  const WelcomeScreen({super.key, this.fromSettings = false});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  static const _slides = [
    (
      Icons.shield,
      'Help in one tap',
      'Press the SOS button. After a 5-second countdown you can cancel, '
          'the app finds your location and prepares an alert for your '
          'trusted contacts.',
    ),
    (
      Icons.people,
      'Your trusted contacts',
      'Save up to 5 people. They are stored only on your device. There is '
          'no account and no login.',
    ),
    (
      Icons.favorite,
      'More ways to stay safe',
      'Use a fake call to leave a situation, set an arrival check, get '
          'guided help from the assistant, and find nearby help and '
          'helplines.',
    ),
    (
      Icons.lock,
      'Your privacy comes first',
      'Your location is used only when you press SOS. Saheli Safe supports '
          'your safety but does not replace emergency services. In an '
          'emergency, call 112.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (!widget.fromSettings) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('seen_welcome', true);
    }
    if (!mounted) return;
    if (widget.fromSettings) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  void _next() {
    if (_page == _slides.length - 1) {
      _finish();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _slides.length - 1;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [kLightPink, Colors.white],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: last ? null : _finish,
                  child: Text(last ? '' : 'Skip'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _slides.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final slide = _slides[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 128,
                            height: 128,
                            decoration: BoxDecoration(
                              color: kDarkPink,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: kGlowPink,
                                  blurRadius: 24,
                                  spreadRadius: 4,
                                ),
                              ],
                            ),
                            child: Icon(
                              slide.$1,
                              color: Colors.white,
                              size: 64,
                            ),
                          ),
                          const SizedBox(height: 32),
                          Text(
                            slide.$2,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            slide.$3,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 16, height: 1.4),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < _slides.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: i == _page ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page ? kDarkPink : kGlowPink,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _next,
                    child: Text(last ? 'Get started' : 'Next'),
                  ),
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
                        icon: Icon(Icons.delete, color: kDarkPink),
                        onPressed: () => _deleteContact(index),
                      ),
                    );
                  },
                ),
    );
  }
}
