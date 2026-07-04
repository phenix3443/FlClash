import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

class VpnManager extends ConsumerStatefulWidget {
  final Widget child;

  const VpnManager({super.key, required this.child});

  @override
  ConsumerState<VpnManager> createState() => _VpnContainerState();
}

class _VpnContainerState extends ConsumerState<VpnManager> {
  Future<void> _pendingSync = Future.value();

  @override
  void initState() {
    super.initState();
    ref.listenManual(vpnStateProvider, (prev, next) {
      if (prev != next) {
        showTip(next);
        _scheduleSync();
      }
    });
    if (system.isOhos) {
      ref.listenManual<bool>(isStartProvider, (prev, next) {
        if (prev != next) {
          _scheduleSync();
        }
      }, fireImmediately: true);
    }
  }

  void _scheduleSync() {
    if (!system.isOhos) {
      return;
    }
    _pendingSync = _pendingSync.then((_) => _syncVpn()).catchError((
      Object error,
    ) {
      commonPrint.log(
        '[OHOS-VPN] sync failed: $error',
        logLevel: LogLevel.warning,
      );
    });
  }

  Future<void> _syncVpn() async {
    if (globalState.isHandlingOhosPendingDebugVpnStart) {
      commonPrint.log(
        '[OHOS-VPN] skip sync during pending debug VPN start handling',
      );
      return;
    }
    final state = ref.read(vpnStateProvider);
    final isStart = ref.read(isStartProvider);
    commonPrint.log(
      '[OHOS-VPN] sync enter isStart=$isStart enable=${state.vpnProps.enable} '
      'stack=${state.stack.name} ipv6=${state.vpnProps.ipv6}',
    );
    if (!isStart || !state.vpnProps.enable) {
      try {
        final stopped = await app?.stopVpn();
        if (stopped != true) {
          throw PlatformException(
            code: 'STOP_VPN_FAILED',
            message: 'OHOS VPN extension did not stop',
          );
        }
      } on PlatformException catch (error) {
        final message = formatOhosVpnStopError(error);
        var messageToShow = message;
        final shouldRestoreRunningState =
            shouldRestoreOhosVpnStateAfterStopFailure(error);
        commonPrint.log(
          '[OHOS-VPN] stop failed: $message '
          'restoreRunningState=$shouldRestoreRunningState',
          logLevel: LogLevel.warning,
        );
        if (shouldRestoreRunningState) {
          final restoredRunningState = await ref
              .read(setupActionProvider.notifier)
              .restoreOhosVpnStateAfterFailedStop();
          if (!restoredRunningState) {
            messageToShow = formatOhosVpnStopRestoreFailure(message);
          }
        } else {
          ref
              .read(setupActionProvider.notifier)
              .clearOhosVpnStopRollbackState();
        }
        globalState.showNotifier(messageToShow);
        return;
      }
      ref.read(setupActionProvider.notifier).clearOhosVpnStopRollbackState();
      await reconnectOhosUiCoreAfterVpnStop(globalState.container);
      await ref.read(systemActionProvider.notifier).updateLocalIp();
      return;
    }
    try {
      final homeDir = await appPath.homeDirPath;
      final setupParams = ref.read(setupActionProvider.notifier).setupParams;
      final initParamsJson = json.encode({
        'home-dir': homeDir,
        'version': ref.read(versionProvider),
      });
      final setupParamsJson = json.encode(setupParams.toJson());
      final started = await app?.startVpn(
        stack: state.stack.name,
        ipv6: state.vpnProps.ipv6,
        initParamsJson: initParamsJson,
        setupParamsJson: setupParamsJson,
        // Let the VPN-process core dial the main app's CoreService socket so the
        // UI is linked to the core that actually serves traffic (live status,
        // traffic stats, connections page, live mode/node switching).
        coreSocketPath: unixSocketPath,
      );
      commonPrint.log('[OHOS-VPN] startVpn returned started=$started');
      if (started != true) {
        throw PlatformException(
          code: 'START_VPN_FAILED',
          message: 'OHOS VPN extension did not start',
        );
      }
      await ref.read(systemActionProvider.notifier).updateLocalIp();
      ref.read(checkIpNumProvider.notifier).add();
    } on PlatformException catch (error) {
      final message = _formatVpnError(error);
      commonPrint.log(
        '[OHOS-VPN] start failed: $message',
        logLevel: LogLevel.warning,
      );
      globalState.showNotifier(message);
      await ref.read(
        setupActionProvider.notifier,
      ).updateStatus(false, captureOhosVpnStopRollbackState: false);
    }
  }

  String _formatVpnError(PlatformException error) {
    return formatOhosVpnStartError(error);
  }

  void showTip(VpnState state) {
    throttler.call(
      FunctionTag.vpnTip,
      () {
        if (!ref.read(isStartProvider) || state == globalState.lastVpnState) {
          return;
        }
        globalState.showNotifier(
          currentAppLocalizations.vpnConfigChangeDetected,
          actionState: MessageActionState(
            actionText: currentAppLocalizations.restart,
            action: () async {
              final setupAction = ref.read(setupActionProvider.notifier);
              await setupAction.handleStop();
              await setupAction.updateStatus(true);
            },
          ),
        );
      },
      duration: const Duration(seconds: 6),
      fire: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
