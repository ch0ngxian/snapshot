import 'package:flutter/material.dart';

/// Onboarding step 3. Surfaces what we store, how long we keep it, and the
/// delete-on-request hook (per tech-plan.md §5.9 + §5.10). Acceptance is
/// required to finish onboarding — there's no "skip" path; the game can't
/// function without face data.
class ConsentScreen extends StatefulWidget {
  final VoidCallback onAccepted;

  const ConsentScreen({super.key, required this.onAccepted});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How your data is used')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'We store a numeric representation of your face on our '
              'servers to make this game work.',
              style: TextStyle(fontSize: 16, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              "We keep an actual photo only when our system is unsure "
              "about a tag — for at most 30 days — to improve accuracy.",
              style: TextStyle(fontSize: 16, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              'You can delete your data any time from Settings.',
              style: TextStyle(fontSize: 16, height: 1.4),
            ),
            const Spacer(),
            CheckboxListTile(
              value: _checked,
              onChanged: (v) => setState(() => _checked = v ?? false),
              title: const Text('I understand and accept.'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _checked ? widget.onAccepted : null,
              child: const Text('Finish setup'),
            ),
          ],
        ),
      ),
    );
  }
}
