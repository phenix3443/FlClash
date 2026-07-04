import 'package:fl_clash/common/ohos_vpn.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:path/path.dart' as path;

void main() {
  group('formatOhosVpnStartError', () {
    test('keeps generic timeout failures generic', () {
      expect(
        formatOhosVpnStartError(
          PlatformException(
            code: 'START_VPN_FAILED',
            message: 'startVpnExtensionAbility timeout',
          ),
        ),
        'VPN 启动失败: startVpnExtensionAbility timeout',
      );
    });

    test('keeps generic failed status errors generic', () {
      expect(
        formatOhosVpnStartError(
          PlatformException(
            code: 'START_VPN_FAILED',
            message: 'vpn extension not ready: failed:{}',
          ),
        ),
        'VPN 启动失败: vpn extension not ready: failed:{}',
      );
    });

    test('surfaces the missing authorization component message only when present', () {
      expect(
        formatOhosVpnStartError(
          PlatformException(
            code: 'START_VPN_FAILED',
            message: 'ability start failed',
            details: 'bundle not exist -n com.huawei.hmos.vpndialog',
          ),
        ),
        'OHOS VPN 授权组件缺失，当前模拟器无法完成系统 VPN 启动',
      );
    });
  });

  group('formatOhosVpnStopError', () {
    test('keeps generic stop failures generic', () {
      expect(
        formatOhosVpnStopError(
          PlatformException(
            code: 'STOP_VPN_FAILED',
            message: 'vpn extension did not stop: failed:stopTun failed',
          ),
        ),
        'VPN 停止失败: vpn extension did not stop: failed:stopTun failed',
      );
    });

    test('surfaces local restore failure after a stop failure', () {
      expect(
        formatOhosVpnStopRestoreFailure(
          'VPN 停止失败: stopVpnExtensionAbility timeout',
        ),
        'VPN 停止失败: stopVpnExtensionAbility timeout；本地运行状态恢复失败，请重新启动应用后检查 VPN 实际状态',
      );
    });

    test('detects stop cleanup residue markers from the native error message', () {
      expect(
        shouldRestoreOhosVpnStateAfterStopFailure(
          PlatformException(
            code: 'STOP_VPN_FAILED',
            message:
                'stopVpnExtensionAbility timeout | stopTun failed: busy | stopTrackedCore failed: busy',
          ),
        ),
        isTrue,
      );
      expect(
        shouldRestoreOhosVpnStateAfterStopFailure(
          PlatformException(
            code: 'STOP_VPN_FAILED',
            message: 'stopVpnExtensionAbility timeout',
          ),
        ),
        isFalse,
      );
    });
  });

  test('OHOS VpnManager treats non-true startVpn results as failures', () async {
    final source = await File(
      path.join(Directory.current.path, 'lib/manager/vpn_manager.dart'),
    ).readAsString();

    expect(
      source,
      matches(
        RegExp(
          r'if \(started != true\) \{[\s\S]*throw PlatformException\(',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VpnManager skips sync while pending debug VPN start owns the native start flow', () async {
    final source = await File(
      path.join(Directory.current.path, 'lib/manager/vpn_manager.dart'),
    ).readAsString();

    expect(
      source,
      matches(
        RegExp(
          r'if \(globalState\.isHandlingOhosPendingDebugVpnStart\) \{[\s\S]*skip sync during pending debug VPN start handling[\s\S]*return;',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin start wait does not treat stopped as an immediate terminal status', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private async waitForVpnStatus\(path: string\): Promise<string> \{[\s\S]*?if \([\s\S]*?status === 'started'[\s\S]*?status\.startsWith\('failed:'\)[\s\S]*?\) \{[\s\S]*?\}[\s\S]*?\}[\s\S]*?private async waitForVpnStoppedStatus",
          multiLine: true,
        ),
      ),
    );
    expect(
      appPluginSource,
      isNot(
        matches(
          RegExp(
            r"private async waitForVpnStatus\(path: string\): Promise<string> \{[\s\S]*?status === 'stopped'[\s\S]*?private async waitForVpnStoppedStatus",
            multiLine: true,
          ),
        ),
      ),
    );
  });

  test('OHOS VpnManager does not treat stopVpn fire-and-forget as a verified stop', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      isNot(
        matches(
          RegExp(
            r'await vpnExtension\.stopVpnExtensionAbility\(want\);[\s\S]*this\.resetVpnStatus\(statusPath\);[\s\S]*result\.success\(true\);',
            multiLine: true,
          ),
        ),
      ),
    );
    expect(
      appPluginSource,
      isNot(
        matches(
          RegExp(
            r'await vpnExtension\.stopVpnExtensionAbility\(want\);[\s\S]*const status = await this\.waitForVpnStatus\(statusPath\);',
            multiLine: true,
          ),
        ),
      ),
    );
    expect(
      appPluginSource,
      matches(
        RegExp(
          r"let stopErrorMessage = '';\s*try \{[\s\S]*await this\.withTimeout\(\s*vpnExtension\.stopVpnExtensionAbility\(want\),\s*3000,\s*'stopVpnExtensionAbility timeout',\s*\);[\s\S]*\} catch \(error\) \{[\s\S]*stopErrorMessage = stringifyError\(error\);[\s\S]*\}[\s\S]*const status = await this\.waitForVpnStoppedStatus\(statusPath\);[\s\S]*const resolution = resolveVpnStopResult\(\{[\s\S]*stopErrorMessage,[\s\S]*status,[\s\S]*\}\);[\s\S]*if \(!resolution\.stopped\) \{",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin bounds stop launcher wait before resolving final stopped status', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"let stopErrorMessage = '';\s*try \{[\s\S]*await this\.withTimeout\(\s*vpnExtension\.stopVpnExtensionAbility\(want\),\s*3000,\s*'stopVpnExtensionAbility timeout',\s*\);[\s\S]*\} catch \(error\) \{[\s\S]*stopErrorMessage = stringifyError\(error\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin retries stop only for teardown-failed VPN status', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();
    final failedStatusIndex = appPluginSource.indexOf(
      'if (currentStatus.startsWith(\'failed:\')) {',
    );
    final retryDecisionIndex = appPluginSource.indexOf(
      'if (!this.shouldRetryFailedVpnStopStatus(currentStatus)) {',
      failedStatusIndex,
    );
    final resetStatusIndex = appPluginSource.indexOf(
      'this.resetVpnStatus(statusPath);',
      failedStatusIndex,
    );
    final stopCallIndex = appPluginSource.indexOf(
      'await this.withTimeout(',
      failedStatusIndex,
    );

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private shouldRetryFailedVpnStopStatus\(status: string\): boolean \{[\s\S]*status\.includes\('stopTun failed:'\)[\s\S]*status\.includes\('stopTrackedCore failed:'\)[\s\S]*status\.includes\('destroy failed:'\)",
          multiLine: true,
        ),
      ),
    );
    expect(failedStatusIndex, isNonNegative);
    expect(retryDecisionIndex, greaterThan(failedStatusIndex));
    expect(resetStatusIndex, greaterThan(failedStatusIndex));
    expect(resetStatusIndex, greaterThan(retryDecisionIndex));
    expect(stopCallIndex, greaterThan(resetStatusIndex));
    expect(
      appPluginSource,
      matches(
        RegExp(
          r"if \(currentStatus\.startsWith\('failed:'\)\) \{[\s\S]*if \(!this\.shouldRetryFailedVpnStopStatus\(currentStatus\)\) \{[\s\S]*result\.success\(true\);[\s\S]*return;[\s\S]*\}[\s\S]*this\.resetVpnStatus\(statusPath\);",
          multiLine: true,
        ),
      ),
    );
    expect(
      appPluginSource,
      matches(
        RegExp(
          r'catch \(error\) \{[\s\S]*nativeBridge\.stopTun\(\);[\s\S]*nativeBridge\.stopTrackedCore\(\);',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin preserves force-cleanup failures when stop fallback also fails', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"catch \(error\) \{[\s\S]*const cleanupErrors: string\[\] = \[\];[\s\S]*const stopped = nativeBridge\.stopTun\(\);[\s\S]*if \(!stopped\) \{[\s\S]*cleanupErrors\.push\(`stopTun failed: \$\{nativeBridge\.lastError\(\)\}`\);[\s\S]*\}[\s\S]*const stopped = nativeBridge\.stopTrackedCore\(\);[\s\S]*if \(!stopped\) \{[\s\S]*cleanupErrors\.push\(`stopTrackedCore failed: \$\{nativeBridge\.lastError\(\)\}`\);[\s\S]*\}[\s\S]*const errorMessage = cleanupErrors\.length > 0[\s\S]*\? `\$\{stringifyError\(error\)\} \| \$\{cleanupErrors\.join\(' \| '\)\}`[\s\S]*: stringifyError\(error\);[\s\S]*result\.error\([\s\S]*'STOP_VPN_FAILED',[\s\S]*errorMessage,",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin keeps in-memory running state when stop failure leaves cleanup errors', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r'catch \(error\) \{[\s\S]*const cleanupErrors: string\[\] = \[\];[\s\S]*const errorMessage = cleanupErrors\.length > 0[\s\S]*console\.error\([\s\S]*if \(cleanupErrors\.length > 0\) \{[\s\S]*this\.isVpnRunning = true;[\s\S]*\} else \{[\s\S]*this\.isVpnRunning = false;[\s\S]*\}[\s\S]*result\.error\(',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin treats start-failed VPN status as already stopped during rollback', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"if \(currentStatus\.startsWith\('failed:'\)\) \{[\s\S]*if \(!this\.shouldRetryFailedVpnStopStatus\(currentStatus\)\) \{[\s\S]*this\.isVpnRunning = false;[\s\S]*result\.success\(true\);[\s\S]*return;",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin does not treat starting VPN status as already stopped', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      isNot(
        matches(
          RegExp(
            r"const currentStatus =[\s\S]*currentStatus !== 'started'[\s\S]*result\.success\(true\);",
            multiLine: true,
          ),
        ),
      ),
    );
    expect(
      appPluginSource,
      matches(
        RegExp(
          r"const vpnRunning = this\.isVpnStatusRunning\(this\.applicationContext\);[\s\S]*if \(\s*currentStatus === 'stopped' \|\|\s*\(currentStatus\.length === 0 && !vpnRunning && !this\.vpnStartInFlight\)\s*\) \{[\s\S]*result\.success\(true\);",
          multiLine: true,
        ),
      ),
    );
    expect(
      appPluginSource,
      isNot(
        matches(
          RegExp(
            r"const currentStatus =[\s\S]*if \(\s*currentStatus === 'starting'\s*\) \{[\s\S]*result\.success\(true\);",
            multiLine: true,
          ),
        ),
      ),
    );
  });

  test('OHOS AppPlugin falls back to in-memory running state when the status file is missing', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private isVpnStatusRunning\(context: common\.Context \| null\): boolean \{[\s\S]*const status = this\.readVpnStatus\(this\.getVpnStatusPath\(context\)\);[\s\S]*return status === 'started' \|\| \(status\.length === 0 && this\.isVpnRunning\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin does not treat a missing VPN status file as already stopped while in-memory state is running', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private async stopVpn\(result: MethodResult\): Promise<void> \{[\s\S]*const vpnRunning = this\.isVpnStatusRunning\(this\.applicationContext\);[\s\S]*if \(\s*currentStatus === 'stopped' \|\|\s*\(currentStatus\.length === 0 && !vpnRunning && !this\.vpnStartInFlight\)\s*\) \{[\s\S]*result\.success\(true\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin clears in-memory running state when stop short-circuits on stopped status', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private async stopVpn\(result: MethodResult\): Promise<void> \{[\s\S]*if \(\s*currentStatus === 'stopped' \|\|\s*\(currentStatus\.length === 0 && !vpnRunning && !this\.vpnStartInFlight\)\s*\) \{[\s\S]*if \(currentStatus === 'stopped'\) \{[\s\S]*this\.isVpnRunning = false;[\s\S]*\}[\s\S]*result\.success\(true\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin serializes concurrent startVpn calls onto the in-flight start result', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(appPluginSource, contains('private vpnStartInFlight = false;'));
    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private async startVpn\([\s\S]*const statusPath = this\.getVpnStatusPath\(abilityContext\);[\s\S]*if \(this\.vpnStartInFlight\) \{[\s\S]*const status = await this\.waitForVpnStatus\(statusPath\);[\s\S]*const resolution = resolveVpnStartResult\(\{[\s\S]*startErrorMessage: '',[\s\S]*status,[\s\S]*\}\);[\s\S]*if \(!resolution\.started\) \{[\s\S]*throw new Error\(resolution\.errorMessage\);[\s\S]*\}[\s\S]*this\.isVpnRunning = true;[\s\S]*result\.success\(true\);[\s\S]*return;",
          multiLine: true,
        ),
      ),
    );
    expect(
      appPluginSource,
      matches(
        RegExp(
          r'private async startVpn\([\s\S]*this\.vpnStartInFlight = true;[\s\S]*try \{[\s\S]*await this\.withTimeout\([\s\S]*\}[\s\S]*finally \{[\s\S]*this\.vpnStartInFlight = false;[\s\S]*\}',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin does not treat an empty status file as already stopped while a start is still in flight', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"private async stopVpn\(result: MethodResult\): Promise<void> \{[\s\S]*let currentStatus = statusPath\.length > 0[\s\S]*if \(currentStatus\.length === 0 && this\.vpnStartInFlight\) \{[\s\S]*currentStatus = await this\.waitForVpnStatus\(statusPath\);[\s\S]*if \(currentStatus\.startsWith\('failed:'\)\) \{[\s\S]*this\.isVpnRunning = false;[\s\S]*result\.success\(true\);[\s\S]*return;[\s\S]*\}[\s\S]*\}[\s\S]*if \(\s*currentStatus === 'stopped' \|\|\s*\(currentStatus\.length === 0 && !vpnRunning && !this\.vpnStartInFlight\)\s*\) \{",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS AppPlugin does not return stop success immediately when start-in-flight status remains empty', () async {
    final appPluginSource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/plugins/AppPlugin.ets',
      ),
    ).readAsString();

    expect(
      appPluginSource,
      matches(
        RegExp(
          r"if \(currentStatus\.length === 0 && this\.vpnStartInFlight\) \{[\s\S]*currentStatus = await this\.waitForVpnStatus\(statusPath\);[\s\S]*if \(currentStatus\.startsWith\('failed:'\)\) \{[\s\S]*result\.success\(true\);[\s\S]*return;[\s\S]*\}[\s\S]*\}[\s\S]*if \(\s*currentStatus === 'stopped' \|\|\s*\(currentStatus\.length === 0 && !vpnRunning && !this\.vpnStartInFlight\)\s*\) \{",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VpnManager does not skip stopVpn based on getVpnRunning state', () async {
    final vpnManagerSource = await File(
      path.join(
        Directory.current.path,
        'lib/manager/vpn_manager.dart',
      ),
    ).readAsString();

    expect(
      vpnManagerSource,
      isNot(contains('final vpnRunning = await app?.getVpnRunning() ?? false;')),
    );
    expect(
      vpnManagerSource,
      isNot(contains('[OHOS-VPN] skip stop because native vpn is not running')),
    );
    expect(
      vpnManagerSource,
      matches(
        RegExp(
          r'if \(!isStart \|\| !state\.vpnProps\.enable\) \{[\s\S]*await app\?\.stopVpn\(\);[\s\S]*return;',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VpnManager treats non-true stopVpn results as failures and restores running state', () async {
    final vpnManagerSource = await File(
      path.join(
        Directory.current.path,
        'lib/manager/vpn_manager.dart',
      ),
    ).readAsString();

    expect(
      vpnManagerSource,
      matches(
        RegExp(
          r"final stopped = await app\?\.stopVpn\(\);[\s\S]*if \(stopped != true\) \{[\s\S]*throw PlatformException\([\s\S]*code: 'STOP_VPN_FAILED'",
          multiLine: true,
        ),
      ),
    );
    expect(
      vpnManagerSource,
      matches(
        RegExp(
          r'on PlatformException catch \(error\) \{[\s\S]*var messageToShow = message;[\s\S]*final shouldRestoreRunningState =[\s\S]*shouldRestoreOhosVpnStateAfterStopFailure\(error\);[\s\S]*if \(shouldRestoreRunningState\) \{[\s\S]*final restoredRunningState = await ref[\s\S]*restoreOhosVpnStateAfterFailedStop\(\);[\s\S]*if \(!restoredRunningState\) \{[\s\S]*messageToShow = formatOhosVpnStopRestoreFailure\(message\);[\s\S]*\}[\s\S]*\} else \{[\s\S]*clearOhosVpnStopRollbackState\(\);[\s\S]*\}[\s\S]*showNotifier\(messageToShow\);',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VpnManager refreshes local IP after successful stop', () async {
    final vpnManagerSource = await File(
      path.join(
        Directory.current.path,
        'lib/manager/vpn_manager.dart',
      ),
    ).readAsString();

    expect(
      vpnManagerSource,
      matches(
        RegExp(
          r'reconnectOhosUiCoreAfterVpnStop\(globalState\.container\);[\s\S]*updateLocalIp\(\);',
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VpnManager refreshes local IP after successful start', () async {
    final vpnManagerSource = await File(
      path.join(
        Directory.current.path,
        'lib/manager/vpn_manager.dart',
      ),
    ).readAsString();

    expect(
      vpnManagerSource,
      matches(
        RegExp(
          r'if \(started != true\) \{[\s\S]*throw PlatformException\([\s\S]*\}[\s\S]*await ref\.read\(systemActionProvider\.notifier\)\.updateLocalIp\(\);',
          multiLine: true,
        ),
      ),
    );
  });

  test(
    'OHOS VpnManager refreshes dashboard network detection after successful start',
    () async {
      final vpnManagerSource = await File(
        path.join(
          Directory.current.path,
          'lib/manager/vpn_manager.dart',
        ),
      ).readAsString();

      expect(
        vpnManagerSource,
        matches(
          RegExp(
            r'await ref\.read\(systemActionProvider\.notifier\)\.updateLocalIp\(\);[\s\S]*ref\.read\(checkIpNumProvider\.notifier\)\.add\(\);',
            multiLine: true,
          ),
        ),
      );
    },
  );

  test('OHOS VPN ability does not write stopped status before teardown finishes', () async {
    final vpnAbilitySource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/vpn/FlClashVpnAbility.ets',
      ),
    ).readAsString();

    expect(
      vpnAbilitySource,
      isNot(
        matches(
          RegExp(
            "async onDestroy\\(\\): Promise<void> \\{\\s*writeVpnStatus\\(this\\.context\\.filesDir, 'stopped'\\);",
            multiLine: true,
          ),
        ),
      ),
    );
    expect(
      vpnAbilitySource,
      matches(
        RegExp(
          "async onDestroy\\(\\): Promise<void> \\{[\\s\\S]*nativeBridge\\.stopTun\\([\\s\\S]*nativeBridge\\.stopTrackedCore\\([\\s\\S]*await this\\.vpnConnection\\?\\.destroy\\([\\s\\S]*writeVpnStatus\\(this\\.context\\.filesDir, 'stopped'\\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VPN ability does not report stopped when teardown steps fail', () async {
    final vpnAbilitySource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/vpn/FlClashVpnAbility.ets',
      ),
    ).readAsString();

    expect(
      vpnAbilitySource,
      matches(
        RegExp(
          r'const teardownErrors: string\[\] = \[\];',
          multiLine: true,
        ),
      ),
    );
    expect(
      vpnAbilitySource,
      matches(
        RegExp(
          r'catch \(error\) \{[\s\S]*teardownErrors\.push\(',
          multiLine: true,
        ),
      ),
    );
    expect(
      vpnAbilitySource,
      matches(
        RegExp(
          r"if \(teardownErrors\.length > 0\) \{[\s\S]*writeVpnStatus\([\s\S]*this\.context\.filesDir,[\s\S]*`failed:\$\{teardownErrors\.join\(' \| '\)\}`,[\s\S]*\);[\s\S]*return;[\s\S]*\}[\s\S]*writeVpnStatus\(this\.context\.filesDir, 'stopped'\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VPN ability preserves cleanup failures when startup rollback after tun start fails', () async {
    final vpnAbilitySource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/vpn/FlClashVpnAbility.ets',
      ),
    ).readAsString();

    expect(
      vpnAbilitySource,
      matches(
        RegExp(
          r"catch \(error\) \{[\s\S]*const errorMessage = stringifyError\(error\);[\s\S]*const cleanupErrors: string\[\] = \[\];[\s\S]*if \(tunStarted\) \{[\s\S]*const stopped = nativeBridge\.stopTun\(\);[\s\S]*if \(!stopped\) \{[\s\S]*cleanupErrors\.push\(`stopTun failed: \$\{nativeBridge\.lastError\(\)\}`\);[\s\S]*\}[\s\S]*const stopped = nativeBridge\.stopTrackedCore\(\);[\s\S]*if \(!stopped\) \{[\s\S]*cleanupErrors\.push\([\s\S]*`stopTrackedCore failed: \$\{nativeBridge\.lastError\(\)\}`[\s\S]*\);[\s\S]*\}[\s\S]*\}[\s\S]*writeVpnStatus\([\s\S]*this\.context\.filesDir,[\s\S]*`failed:\$\{errorMessage\}\$\{cleanupErrors\.length > 0 \? ` \| \$\{cleanupErrors\.join\(' \| '\)\}` : ''\}`,[\s\S]*\);",
          multiLine: true,
        ),
      ),
    );
  });

  test('OHOS VPN ability preserves destroy failures when startup rollback cleanup fails', () async {
    final vpnAbilitySource = await File(
      path.join(
        Directory.current.path,
        'ohos/entry/src/main/ets/vpn/FlClashVpnAbility.ets',
      ),
    ).readAsString();

    expect(
      vpnAbilitySource,
      matches(
        RegExp(
          r"catch \(error\) \{[\s\S]*const cleanupErrors: string\[\] = \[\];[\s\S]*try \{[\s\S]*await this\.vpnConnection\?\.destroy\(\);[\s\S]*\} catch \(cleanupError\) \{[\s\S]*cleanupErrors\.push\(`destroy failed: \$\{stringifyError\(cleanupError\)\}`\);[\s\S]*\}[\s\S]*writeVpnStatus\([\s\S]*`failed:\$\{errorMessage\}\$\{cleanupErrors\.length > 0 \? ` \| \$\{cleanupErrors\.join\(' \| '\)\}` : ''\}`",
          multiLine: true,
        ),
      ),
    );
  });
}
