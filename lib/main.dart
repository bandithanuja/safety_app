import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
// APP
// ---------------------------------------------------------------
class SafetyApp extends StatelessWidget {
  const SafetyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Safety App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.red,
        useMaterial3: true,
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
              onPressed: () => Navigator.pop(ctx, true),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety App'),
        actions: [
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
                    color: Colors.red,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.red.shade200,
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

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _ringTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => HapticFeedback.heavyImpact(),
    );
  }

  @override
  void dispose() {
    _callTimer?.cancel();
    _ringTimer?.cancel();
    super.dispose();
  }

  void _answer() {
    _ringTimer?.cancel();
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
      body: SafeArea(
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
      if (!mounted) return;
      final link = LocationService.mapsLink(position);
      setState(() {
        _link = link;
        _message = 'EMERGENCY! I need help. My current location: $link';
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

  Future<void> _openMap() async {
    await launchUrl(Uri.parse(_link), mode: LaunchMode.externalApplication);
  }

  Future<void> _sendSms(Contact contact) async {
    final ok = await openSms(contact.phone, _message);
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
                color: Colors.red,
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
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(_message),
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
            const Icon(Icons.error_outline, color: Colors.red, size: 72),
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
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteContact(index),
                      ),
                    );
                  },
                ),
    );
  }
}