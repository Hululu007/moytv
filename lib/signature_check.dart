import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const releaseSignatureSha256 =
    '643598842f96bc925b80f84480e96ee6f16e56fe53030228f26e9d00d5e8e76f';

const signatureCheckEnforced = false;

bool isSignatureAllowed(String? actual) =>
    actual == null || actual == releaseSignatureSha256;

Future<bool> checkReleaseSignature() async {
  if (!kReleaseMode || !Platform.isAndroid) return true;
  try {
    final actual = await const MethodChannel(
      'moyi/device',
    ).invokeMethod<String>('signatureSha256');
    return isSignatureAllowed(actual);
  } catch (_) {
    return true;
  }
}

class TamperScreen extends StatelessWidget {
  const TamperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.warning_rounded, size: 56, color: colors.error),
              const SizedBox(height: 16),
              const Text(
                '应用签名异常',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                '当前安装包签名与发版签名不一致，无法继续使用。请从官方渠道重新下载安装。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: () => exit(0), child: const Text('退出应用')),
            ],
          ),
        ),
      ),
    );
  }
}
