import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/lobby_repository.dart';

/// Joiner entry point. Defaults to manual code entry with a "Scan QR"
/// affordance one tap away (tech-plan §163: QR is the primary path with
/// manual entry as the accessibility fallback). Both paths converge on
/// [LobbyRepository.joinLobby] and report the resulting lobbyId via
/// [onJoined] so the caller can navigate to the waiting room.
class JoinLobbyScreen extends StatefulWidget {
  final LobbyRepository repo;
  final ValueChanged<String> onJoined;

  /// Test override that replaces the live `mobile_scanner` feed with a
  /// fixed stream of decoded codes. Each emitted value is treated as if
  /// it had been read from a QR.
  @visibleForTesting
  final Stream<String>? scanStreamOverride;

  const JoinLobbyScreen({
    super.key,
    required this.repo,
    required this.onJoined,
    this.scanStreamOverride,
  });

  @override
  State<JoinLobbyScreen> createState() => _JoinLobbyScreenState();
}

final RegExp _codePattern = RegExp(r'^[A-Z0-9]{6}$');

class _JoinLobbyScreenState extends State<JoinLobbyScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _attemptJoin(String raw) async {
    if (_busy) return;
    final code = raw.trim().toUpperCase();
    if (!_codePattern.hasMatch(code)) {
      setState(() => _error = 'Codes are 6 characters (A–Z, 0–9).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final lobbyId = await widget.repo.joinLobby(code);
      if (!mounted) return;
      widget.onJoined(lobbyId);
    } on LobbyNotFoundException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "We couldn't find that lobby — check the code and try again.";
      });
    } on LobbyFullException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'That lobby is full.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Failed to join: $e';
      });
    }
  }

  Future<void> _openScanner() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _QrScanScreen(streamOverride: widget.scanStreamOverride),
      ),
    );
    if (scanned == null) return;
    _controller.text = scanned;
    await _attemptJoin(scanned);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join lobby')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Scan the host's QR code, or type the 6-character code they're showing.",
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _openScanner,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
            ),
            const SizedBox(height: 16),
            const _DividerWithLabel(label: 'or type the code'),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 6,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'ABC123',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                _UppercaseFormatter(),
              ],
              textInputAction: TextInputAction.go,
              onSubmitted: _attemptJoin,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : () => _attemptJoin(_controller.text),
              child: Text(_busy ? 'Joining…' : 'Join'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DividerWithLabel extends StatelessWidget {
  final String label;
  const _DividerWithLabel({required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label, style: const TextStyle(color: Colors.black54)),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

class _UppercaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

/// Camera-feed QR scanner. Pops the route with the decoded code on the first
/// successful scan. The test path swaps the camera stream for an injected
/// one so widget tests don't need a platform-channel fake.
class _QrScanScreen extends StatefulWidget {
  final Stream<String>? streamOverride;
  const _QrScanScreen({this.streamOverride});

  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<_QrScanScreen> {
  StreamSubscription<String>? _override;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    final override = widget.streamOverride;
    if (override != null) {
      _override = override.listen(_pop);
    }
  }

  @override
  void dispose() {
    _override?.cancel();
    super.dispose();
  }

  void _pop(String code) {
    if (_popped) return;
    _popped = true;
    Navigator.of(context).pop(code);
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      _pop(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: widget.streamOverride != null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Scanning…'),
              ),
            )
          : MobileScanner(onDetect: _onDetect),
    );
  }
}
