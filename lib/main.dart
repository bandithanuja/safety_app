import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const SafetyApp());

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
// HOME SCREEN: big SOS button + two helper buttons
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'In danger? Press SOS',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 32),
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
            const SizedBox(height: 48),
            ElevatedButton.icon(
              onPressed: () =>
                  _showMessage(context, 'Emergency call comes on Day 4'),
              icon: const Icon(Icons.call),
              label: const Text('Call Emergency'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () =>
                  _showMessage(context, 'Fake call comes on Day 5'),
              icon: const Icon(Icons.phone_in_talk),
              label: const Text('Fake Call'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// SOS SCREEN: 5-second countdown -> get location -> build message
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
              const Icon(Icons.check_circle, color: Colors.green, size: 72),
              const SizedBox(height: 12),
              const Text(
                'Alert ready',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(_message),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Will be sent to:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              ...widget.contacts.map(
                (c) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.person),
                  title: Text(c.name),
                  subtitle: Text(c.phone),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Real SMS sending is added on Day 4.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
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
      appBar: AppBar(title: const Text('Trusted Contacts')),
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