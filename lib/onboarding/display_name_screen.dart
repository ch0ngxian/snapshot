import 'package:flutter/material.dart';

/// First step of onboarding. The user picks a display name. We don't
/// duplicate-check at v1 — friends/family lobbies use real names.
class DisplayNameScreen extends StatefulWidget {
  final ValueChanged<String> onContinue;

  const DisplayNameScreen({super.key, required this.onContinue});

  @override
  State<DisplayNameScreen> createState() => _DisplayNameScreenState();
}

class _DisplayNameScreenState extends State<DisplayNameScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Pick a name your friends will recognize.');
      return;
    }
    if (name.length > 20) {
      setState(() => _error = 'Keep it under 20 characters.');
      return;
    }
    widget.onContinue(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your name')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "What should we call you in lobbies?",
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'e.g. Alex',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              maxLength: 20,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submit,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
