import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// EQ and boost for the whole session (eqMac style): ten bands, presets, and a boost past 100 %
/// with a limiter. Every phone plays through it, including this one.
class EqCard extends ConsumerWidget {
  const EqCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eq = ref.watch(eqProvider);
    final n = ref.read(eqProvider.notifier);
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GPSectionLabel('Sound'),
        GPCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(GPSpace.md, GPSpace.sm, GPSpace.md, 0),
                child: Row(
                  children: [
                    const GPIconTile(CupertinoIcons.slider_horizontal_3),
                    const SizedBox(width: GPSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('EQ & Boost', style: GPText.headline),
                          Text('Every phone plays through it.', style: GPText.footnote.copyWith(color: secondary)),
                        ],
                      ),
                    ),
                    CupertinoSwitch(value: eq.enabled, onChanged: (v) => unawaited(n.setEnabled(v))),
                  ],
                ),
              ),
              Opacity(
                opacity: eq.enabled ? 1 : 0.45,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Presets(selected: eq.enabled ? eq.preset : null, onPick: (p) => unawaited(n.setPreset(p))),
                    _Bands(bands: eq.bands, onChanged: (i, db, {required save}) => unawaited(n.setBand(i, db, save: save))),
                    GPSliderCell(
                      label: 'Boost',
                      value: eq.boostDb,
                      min: 0,
                      max: eqMaxBoostDb,
                      step: 0.5,
                      format: (v) => v == 0 ? 'Off' : '+${v.toStringAsFixed(1)} dB',
                      hint: 'Louder than full volume. A limiter keeps it from clipping.',
                      onChanged: (v) => unawaited(n.setBoost(v, save: false)),
                      onChangeEnd: (v) => unawaited(n.setBoost(v)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Presets extends StatelessWidget {
  const _Presets({required this.selected, required this.onPick});

  final String? selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(GPSpace.md, GPSpace.sm, GPSpace.md, 0),
      child: Row(
        children: [
          for (final name in eqPresets.keys)
            Padding(
              padding: const EdgeInsets.only(right: GPSpace.xs),
              child: _Chip(label: name, selected: name == selected, onTap: () => onPick(name)),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = GPColors.of(context, selected ? GPColors.ink : GPColors.fill);
    final fg = GPColors.of(context, selected ? GPColors.onInk : GPColors.label);
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: () {
          unawaited(GPHaptics.selection());
          onTap();
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: GPSpace.sm, vertical: GPSpace.xs),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(17)),
          child: Text(label, style: GPText.subheadline.copyWith(color: fg)),
        ),
      ),
    );
  }
}

typedef _BandChanged = void Function(int band, double db, {required bool save});

class _Bands extends StatelessWidget {
  const _Bands({required this.bands, required this.onChanged});

  final List<double> bands;
  final _BandChanged onChanged;

  static String _hz(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

  @override
  Widget build(BuildContext context) {
    final secondary = GPColors.of(context, GPColors.secondaryLabel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(GPSpace.xs, GPSpace.sm, GPSpace.xs, 0),
      child: SizedBox(
        height: 190,
        child: Row(
          children: [
            for (var i = 0; i < eqBandHz.length; i++)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      bands[i] == 0 ? '0' : '${bands[i] > 0 ? '+' : ''}${bands[i].round()}',
                      style: GPText.caption1.copyWith(color: secondary, fontFeatures: GPText.tabular),
                    ),
                    Expanded(
                      child: Semantics(
                        label: '${_hz(eqBandHz[i])} hertz',
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: CupertinoSlider(
                            value: bands[i].clamp(-eqMaxBandDb, eqMaxBandDb),
                            min: -eqMaxBandDb,
                            max: eqMaxBandDb,
                            divisions: 48,
                            onChanged: (v) => onChanged(i, v, save: false),
                            onChangeEnd: (v) => onChanged(i, v, save: true),
                          ),
                        ),
                      ),
                    ),
                    Text(_hz(eqBandHz[i]), style: GPText.caption1.copyWith(color: secondary)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
