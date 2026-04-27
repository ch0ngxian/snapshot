import 'package:flutter/material.dart';

import '../models/lobby.dart';

/// Stepper-based editor for the host-configurable round rules
/// (tech-plan §322). Bounds mirror the server-side validation in
/// `functions/src/startRound.ts` — keeping them in lockstep avoids the
/// "stepper says 6 lives but the server rejects 6" failure mode.
class RulesEditor extends StatelessWidget {
  static const int minLives = 1;
  static const int maxLives = 5;
  static const int minDurationSeconds = 60;
  static const int maxDurationSeconds = 1800;
  static const int durationStepSeconds = 60;
  static const int minImmunitySeconds = 0;
  static const int maxImmunitySeconds = 60;
  static const int immunityStepSeconds = 5;

  final LobbyRules value;
  final ValueChanged<LobbyRules> onChanged;
  final bool enabled;

  const RulesEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Game rules',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        _StepperRow(
          label: 'Lives',
          display: '${value.startingLives}',
          onDec: enabled && value.startingLives > minLives
              ? () => onChanged(_copy(startingLives: value.startingLives - 1))
              : null,
          onInc: enabled && value.startingLives < maxLives
              ? () => onChanged(_copy(startingLives: value.startingLives + 1))
              : null,
        ),
        _StepperRow(
          label: 'Duration',
          display: '${value.durationSeconds ~/ 60} min',
          onDec: enabled && value.durationSeconds > minDurationSeconds
              ? () => onChanged(
                    _copy(durationSeconds: value.durationSeconds - durationStepSeconds),
                  )
              : null,
          onInc: enabled && value.durationSeconds < maxDurationSeconds
              ? () => onChanged(
                    _copy(durationSeconds: value.durationSeconds + durationStepSeconds),
                  )
              : null,
        ),
        _StepperRow(
          label: 'Immunity',
          display: '${value.immunitySeconds}s',
          onDec: enabled && value.immunitySeconds > minImmunitySeconds
              ? () => onChanged(
                    _copy(
                      immunitySeconds:
                          value.immunitySeconds - immunityStepSeconds,
                    ),
                  )
              : null,
          onInc: enabled && value.immunitySeconds < maxImmunitySeconds
              ? () => onChanged(
                    _copy(
                      immunitySeconds:
                          value.immunitySeconds + immunityStepSeconds,
                    ),
                  )
              : null,
        ),
      ],
    );
  }

  LobbyRules _copy({
    int? startingLives,
    int? durationSeconds,
    int? immunitySeconds,
  }) {
    return LobbyRules(
      startingLives: startingLives ?? value.startingLives,
      durationSeconds: durationSeconds ?? value.durationSeconds,
      immunitySeconds: immunitySeconds ?? value.immunitySeconds,
    );
  }
}

class _StepperRow extends StatelessWidget {
  final String label;
  final String display;
  final VoidCallback? onDec;
  final VoidCallback? onInc;

  const _StepperRow({
    required this.label,
    required this.display,
    required this.onDec,
    required this.onInc,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            tooltip: 'Decrease $label',
            onPressed: onDec,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 64,
            child: Text(
              display,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: 'Increase $label',
            onPressed: onInc,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}
