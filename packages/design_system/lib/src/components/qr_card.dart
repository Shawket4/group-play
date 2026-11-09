import 'package:design_system/src/tokens/colors.dart';
import 'package:design_system/src/tokens/dimens.dart';
import 'package:design_system/src/tokens/typography.dart';
import 'package:flutter/cupertino.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A QR code on a white plate (scanners need light quiet zones in dark mode too).
class GPQrCode extends StatelessWidget {
  const GPQrCode({required this.data, super.key, this.size = 220, this.semanticLabel = 'QR code'});

  final String data;
  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: semanticLabel,
      child: Container(
        padding: EdgeInsets.all(size * 0.06),
        decoration: BoxDecoration(
          color: CupertinoColors.white,
          borderRadius: BorderRadius.circular(GPRadius.large),
        ),
        child: QrImageView(
          data: data,
          size: size,
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

/// QR + caption, centred in a section cell.
class GPQrCell extends StatelessWidget {
  const GPQrCell({required this.data, required this.caption, super.key});

  final String data;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: GPSpace.lg, horizontal: GPSpace.md),
      child: Column(
        children: [
          Center(child: GPQrCode(data: data, semanticLabel: 'Join code. $caption')),
          const SizedBox(height: GPSpace.md),
          Text(
            caption,
            textAlign: TextAlign.center,
            style: GPText.subheadline.copyWith(color: GPColors.of(context, GPColors.secondaryLabel)),
          ),
        ],
      ),
    );
  }
}
