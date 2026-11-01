import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:library_sync/library_sync.dart';

class SigningExpiry {
  const SigningExpiry(this.expiration);
  final DateTime? expiration;

  factory SigningExpiry.fromNative(Object? value) {
    if (value is Map && value['status'] == 'known') {
      final milliseconds = value['expirationMilliseconds'];
      if (milliseconds is int &&
          milliseconds >= 0 &&
          milliseconds <= 253402300799000) {
        return SigningExpiry(
          DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
        );
      }
    }
    return const SigningExpiry(null);
  }

  String label(DateTime now) {
    final date = expiration;
    if (date == null) return '签名待确认';
    final remaining = date.difference(now);
    if (remaining <= Duration.zero) return '签名已到期';
    if (remaining.inDays >= 1) return '签名剩余${remaining.inDays}天';
    if (remaining.inHours >= 1) return '签名剩余${remaining.inHours}小时';
    if (remaining.inMinutes >= 1) return '签名剩余${remaining.inMinutes}分钟';
    return '签名不足1分钟';
  }

  bool nearExpiry(DateTime now) =>
      expiration != null &&
      expiration!.difference(now) < const Duration(days: 1);

  String get exactLocalTime {
    final date = expiration?.toLocal();
    if (date == null) return '到期时间待确认';
    String two(int number) => number.toString().padLeft(2, '0');
    final offset = date.timeZoneOffset;
    final zone =
        '${offset.isNegative ? '-' : '+'}'
        '${two(offset.inHours.abs())}:${two(offset.inMinutes.abs() % 60)}';
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)} (UTC$zone)';
  }
}

/// A self-contained leaf: countdown updates never notify or rebuild the library.
class SigningExpiryChip extends StatefulWidget {
  const SigningExpiryChip({
    super.key,
    this.onRead,
    this.pairedDevice = false,
    this.pairedStatus,
    this.unavailable,
    this.onRefresh,
  });
  final ValueChanged<SigningExpiry>? onRead;
  final bool pairedDevice;
  final ValueListenable<SigningStatusReceipt?>? pairedStatus;
  final ValueListenable<bool>? unavailable;
  final Future<void> Function()? onRefresh;

  @override
  State<SigningExpiryChip> createState() => _SigningExpiryChipState();
}

class _SigningExpiryChipState extends State<SigningExpiryChip>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('score_reader/signing_expiry');
  SigningExpiry _expiry = const SigningExpiry(null);
  Timer? _timer;
  bool _reading = false;
  bool _foreground = true;
  bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    if (_ios || widget.pairedDevice) {
      _foreground =
          WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      WidgetsBinding.instance.addObserver(this);
      if (widget.pairedDevice) {
        widget.pairedStatus?.addListener(_receiptChanged);
        widget.unavailable?.addListener(_receiptChanged);
        _receiptChanged();
      } else {
        unawaited(_refresh());
      }
    }
  }

  void _receiptChanged() {
    if (!mounted) return;
    setState(
      () => _expiry = SigningExpiry(
        widget.pairedStatus?.value?.status.expiration,
      ),
    );
    _scheduleLabel();
  }

  @override
  void didUpdateWidget(covariant SigningExpiryChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pairedStatus != widget.pairedStatus) {
      oldWidget.pairedStatus?.removeListener(_receiptChanged);
      widget.pairedStatus?.addListener(_receiptChanged);
      if (widget.pairedDevice) _receiptChanged();
    }
    if (oldWidget.unavailable != widget.unavailable) {
      oldWidget.unavailable?.removeListener(_receiptChanged);
      widget.unavailable?.addListener(_receiptChanged);
      if (widget.pairedDevice) _receiptChanged();
    }
  }

  Future<void> _refresh() async {
    if (!_ios || widget.pairedDevice || _reading || !mounted) return;
    _reading = true;
    SigningExpiry result;
    try {
      result = SigningExpiry.fromNative(
        await _channel.invokeMethod('expiration'),
      );
    } on PlatformException {
      result = const SigningExpiry(null);
    } on MissingPluginException {
      result = const SigningExpiry(null);
    }
    _reading = false;
    if (!mounted) return;
    setState(() => _expiry = result);
    widget.onRead?.call(result);
    _scheduleLabel();
  }

  void _scheduleLabel() {
    _timer?.cancel();
    if (!_foreground || _expiry.expiration == null) return;
    final remaining = _expiry.expiration!.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    // No file/channel IO: a minute tick only updates this small display leaf.
    final delay = remaining < const Duration(minutes: 1)
        ? remaining
        : const Duration(minutes: 1);
    _timer = Timer(delay, () {
      if (!mounted) return;
      setState(() {});
      _scheduleLabel();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      if (widget.pairedDevice) {
        _receiptChanged();
      } else {
        unawaited(_refresh());
      }
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _details() async {
    await widget.onRefresh?.call();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => widget.pairedDevice && widget.pairedStatus != null
          ? ValueListenableBuilder<SigningStatusReceipt?>(
              valueListenable: widget.pairedStatus!,
              builder: (context, receipt, _) =>
                  _detailsDialog(context, receipt),
            )
          : _detailsDialog(context, null),
    );
  }

  Widget _detailsDialog(BuildContext context, SigningStatusReceipt? receipt) {
    final display = widget.pairedDevice
        ? SigningExpiry(receipt?.status.expiration)
        : _expiry;
    return AlertDialog(
      title: Text(widget.pairedDevice ? 'iPad 签名上次回报' : '签名到期时间'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.pairedDevice && receipt == null
                ? widget.unavailable?.value == true
                      ? '签名信息暂不可读，请重试。'
                      : '尚未收到当前配对 iPad 的签名回报。'
                : display.expiration == null
                ? widget.pairedDevice
                      ? '已收到回报，暂未读取到到期时间。'
                      : '暂未读取到到期时间。'
                : display.exactLocalTime,
          ),
          if (widget.pairedDevice && receipt != null) ...[
            const SizedBox(height: 8),
            Text('电脑收到：${SigningExpiry(receipt.receivedAt).exactLocalTime}'),
            if (receipt.status.expiration == null &&
                receipt.lastKnownExpiration != null) ...[
              const SizedBox(height: 8),
              Text(
                '上次读到的到期时间：${SigningExpiry(receipt.lastKnownExpiration).exactLocalTime}',
              ),
              Text(
                '该次确认：${SigningExpiry(receipt.lastKnownReceivedAt).exactLocalTime}',
              ),
            ],
          ],
          const SizedBox(height: 16),
          const Text('自动续签由电脑Sideloadly处理，需电脑运行且iPad可见；功能更新需安装新版。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ios && !widget.pairedDevice) return const SizedBox.shrink();
    final now = DateTime.now();
    final receipt = widget.pairedStatus?.value;
    final label = widget.pairedDevice
        ? receipt == null
              ? widget.unavailable?.value == true
                    ? 'iPad签名暂不可读'
                    : 'iPad签名未回报'
              : receipt.status.expiration == null
              ? 'iPad期限未读取'
              : 'iPad${_expiry.label(now)}'
        : _expiry.expiration == null
        ? '签名期限未读取'
        : _expiry.label(now);
    final color = _expiry.nearExpiry(now)
        ? const Color(0xff946124)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: widget.pairedDevice ? 'iPad 签名上次回报；点击查看电脑确认时间' : '查看签名到期时间与续签方式',
      child: TextButton(
        onPressed: _details,
        style: TextButton.styleFrom(
          foregroundColor: color,
          backgroundColor: color.withValues(alpha: .07),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.padded,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: Theme.of(context).textTheme.labelLarge
              ?.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.pairedDevice) ...[
              const Icon(Icons.history, size: 13),
              const SizedBox(width: 4),
            ],
            Text(label),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.pairedStatus?.removeListener(_receiptChanged);
    widget.unavailable?.removeListener(_receiptChanged);
    if (_ios || widget.pairedDevice) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
