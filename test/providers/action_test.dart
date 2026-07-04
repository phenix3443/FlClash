import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

void main() {
  group('ProfilesAction', () {
    test('keeps edited profile data when remote update fails', () async {
      final original = Profile.normal(label: 'old label', url: 'bad-url');
      final edited = original.copyWith(
        label: 'new label',
        url: 'still-bad-url',
      );
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles([original])),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(profilesProvider).getProfile(original.id),
        original,
      );

      await expectLater(
        container.read(profilesActionProvider.notifier).updateProfile(edited),
        throwsA(anything),
      );

      final profile = container.read(profilesProvider).getProfile(original.id);
      expect(profile?.label, edited.label);
      expect(profile?.url, edited.url);
    });
  });

  group('CoreAction', () {
    test('pending debug vpn finalization returns false when init start fails', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final setupAction = container.read(setupActionProvider.notifier);
      setupAction.applyProfileOnInitStart = ({preloadInvoke}) async => false;

      final result = await finalizePendingDebugVpnStart(container);

      expect(result.finalized, isFalse);
      expect(
        result.failureMessage,
        'VPN 启动失败；本地初始化失败后原生 VPN 回滚失败。VPN 停止失败；请重新启动应用后检查 VPN 实际状态',
      );
      expect(container.read(isStartProvider), isFalse);
    });

    test('pending debug vpn finalization rolls back native VPN when init start fails', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final previousRollback = stopPendingDebugVpnAfterFailedInitStart;
      addTearDown(() {
        stopPendingDebugVpnAfterFailedInitStart = previousRollback;
      });

      var stopCalls = 0;
      stopPendingDebugVpnAfterFailedInitStart = () async {
        stopCalls += 1;
        return true;
      };

      final setupAction = container.read(setupActionProvider.notifier);
      setupAction.applyProfileOnInitStart = ({preloadInvoke}) async => false;

      final result = await finalizePendingDebugVpnStart(container);

      expect(result.finalized, isFalse);
      expect(result.failureMessage, 'VPN 启动失败');
      expect(stopCalls, 1);
    });

    test('pending debug vpn finalization surfaces native rollback failure details after init start fails', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final previousRollback = stopPendingDebugVpnAfterFailedInitStart;
      addTearDown(() {
        stopPendingDebugVpnAfterFailedInitStart = previousRollback;
      });

      stopPendingDebugVpnAfterFailedInitStart = () async {
        throw PlatformException(
          code: 'STOP_VPN_FAILED',
          message: 'stopVpnExtensionAbility timeout | stopTun failed: busy',
        );
      };

      final setupAction = container.read(setupActionProvider.notifier);
      setupAction.applyProfileOnInitStart = ({preloadInvoke}) async => false;

      final result = await finalizePendingDebugVpnStart(container);

      expect(result.finalized, isFalse);
      expect(
        result.failureMessage,
        'VPN 启动失败；本地初始化失败后原生 VPN 回滚失败。VPN 停止失败: stopVpnExtensionAbility timeout | stopTun failed: busy；请重新启动应用后检查 VPN 实际状态',
      );
    });

    test(
      'skipped ohos ui core startup sequence still attempts transport connection',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreStatusProvider.overrideWithBuild(
              (_, _) => CoreStatus.disconnected,
            ),
            vpnSettingProvider.overrideWithBuild(
              (_, _) => const VpnProps(enable: true),
            ),
            versionProvider.overrideWithBuild((_, _) => 1),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(coreActionProvider.notifier);
        final previousRunStartupInitStatus = runStartupInitStatus;
        addTearDown(() {
          runStartupInitStatus = previousRunStartupInitStatus;
        });
        runStartupInitStatus = (_) async {};
        var preloadCalls = 0;
        notifier.preloadCore = () async {
          preloadCalls += 1;
          return '';
        };
        notifier.showCoreConnectFailure = (_) {};
        notifier.isCoreInit = () async => false;
        notifier.runCoreInit = (_) async => true;

        await runSkippedOhosUiCoreStartupSequence(
          container,
          isOhosOverride: true,
        );

        expect(preloadCalls, 1);
        expect(container.read(coreStatusProvider), CoreStatus.connected);
      },
    );

    test(
      'skipped ohos ui core startup sequence keeps runtime stopped after transport connects',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreStatusProvider.overrideWithBuild(
              (_, _) => CoreStatus.disconnected,
            ),
            runTimeProvider.overrideWithBuild((_, _) => null),
            vpnSettingProvider.overrideWithBuild(
              (_, _) => const VpnProps(enable: true),
            ),
            versionProvider.overrideWithBuild((_, _) => 1),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(coreActionProvider.notifier);
        final previousRunStartupInitStatus = runStartupInitStatus;
        addTearDown(() {
          runStartupInitStatus = previousRunStartupInitStatus;
        });
        runStartupInitStatus = (_) async {};
        notifier.preloadCore = () async => '';
        notifier.showCoreConnectFailure = (_) {};
        notifier.isCoreInit = () async => false;
        notifier.runCoreInit = (_) async => true;

        await runSkippedOhosUiCoreStartupSequence(
          container,
          isOhosOverride: true,
        );

        expect(container.read(coreStatusProvider), CoreStatus.connected);
        expect(container.read(isStartProvider), isFalse);
        expect(container.read(runTimeProvider), isNull);
      },
    );

    test(
      'skipped ohos ui core startup sequence still initializes core after transport connects',
      () async {
        final container = ProviderContainer(
          overrides: [
            coreStatusProvider.overrideWithBuild(
              (_, _) => CoreStatus.disconnected,
            ),
            vpnSettingProvider.overrideWithBuild(
              (_, _) => const VpnProps(enable: true),
            ),
            versionProvider.overrideWithBuild((_, _) => 1),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(coreActionProvider.notifier);
        final previousRunStartupInitStatus = runStartupInitStatus;
        addTearDown(() {
          runStartupInitStatus = previousRunStartupInitStatus;
        });
        runStartupInitStatus = (_) async {};
        notifier.preloadCore = () async => '';
        notifier.showCoreConnectFailure = (_) {};
        var isCoreInitChecks = 0;
        var initCalls = 0;
        var initVersion = 0;
        notifier.isCoreInit = () async {
          isCoreInitChecks += 1;
          return false;
        };
        notifier.runCoreInit = (version) async {
          initCalls += 1;
          initVersion = version;
          return true;
        };

        await runSkippedOhosUiCoreStartupSequence(
          container,
          isOhosOverride: true,
        );

        expect(container.read(coreStatusProvider), CoreStatus.connected);
        expect(isCoreInitChecks, 1);
        expect(initCalls, 1);
        expect(initVersion, 1);
      },
    );

    test('ohos vpn stop reconnects the app ui core transport', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild(
            (_, _) => CoreStatus.disconnected,
          ),
          vpnSettingProvider.overrideWithBuild(
            (_, _) => const VpnProps(enable: true),
          ),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      final previousPostStopSync = runOhosUiCorePostVpnStopSync;
      addTearDown(() {
        runOhosUiCorePostVpnStopSync = previousPostStopSync;
      });
      notifier.preloadCore = () async => '';
      notifier.showCoreConnectFailure = (_) {};
      var initCalls = 0;
      notifier.isCoreInit = () async => false;
      notifier.runCoreInit = (_) async {
        initCalls += 1;
        return true;
      };
      var profileSyncCalls = 0;
      runOhosUiCorePostVpnStopSync = (_) async {
        profileSyncCalls += 1;
        return true;
      };

      await reconnectOhosUiCoreAfterVpnStop(container);

      expect(container.read(coreStatusProvider), CoreStatus.connected);
      expect(initCalls, 1);
      expect(profileSyncCalls, 1);
    });

    test('pending debug vpn start forces local vpn enable before syncing startup state', () {
      final container = ProviderContainer(
        overrides: [
          vpnSettingProvider.overrideWithBuild(
            (_, _) => const VpnProps(enable: false, ipv6: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      applyPendingDebugVpnStartSettings(
        container,
        stack: TunStack.gvisor.name,
        ipv6: true,
      );

      final vpnSetting = container.read(vpnSettingProvider);
      final patchConfig = container.read(patchClashConfigProvider);
      expect(vpnSetting.enable, isTrue);
      expect(vpnSetting.ipv6, isTrue);
      expect(patchConfig.tun.stack, TunStack.gvisor);
    });

    test('ui core startup sequence stops after connectCore failure', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      notifier.preloadCore = () async => 'core connection timeout';
      notifier.showCoreConnectFailure = (_) {};
      notifier.isCoreInit = () async {
        fail('initCore should not run after connectCore failure');
      };

      await runUiCoreStartupSequence(container);

      expect(container.read(coreStatusProvider), CoreStatus.disconnected);
    });

    test('connectCore coalesces concurrent startup attempts', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      notifier.showCoreConnectFailure = (_) {};
      var preloadCalls = 0;
      final preloadCompleter = Completer<String>();
      notifier.preloadCore = () {
        preloadCalls += 1;
        return preloadCompleter.future;
      };

      final firstConnect = notifier.connectCore();
      final secondConnect = notifier.connectCore();

      expect(preloadCalls, 1);
      expect(container.read(coreStatusProvider), CoreStatus.connecting);

      preloadCompleter.complete('');
      await Future.wait([firstConnect, secondConnect]);

      expect(preloadCalls, 1);
      expect(container.read(coreStatusProvider), CoreStatus.connected);
    });

    test('initCore throws when core init returns false', () async {
      final container = ProviderContainer(
        overrides: [
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      var initVersion = 0;
      notifier.isCoreInit = () async => false;
      notifier.runCoreInit = (version) async {
        initVersion = version;
        return false;
      };

      await expectLater(notifier.initCore(), throwsA(anything));
      expect(initVersion, 1);
    });

    test('restartCore stops after connectCore failure', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
          versionProvider.overrideWithBuild((_, _) => 1),
          isStartProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      var shutdownCalls = 0;
      var initCalls = 0;
      notifier.shutdownCore = (_) async {
        shutdownCalls += 1;
      };
      notifier.preloadCore = () async => 'core connection timeout';
      notifier.initCoreOverride = () async {
        initCalls += 1;
      };
      notifier.showCoreConnectFailure = (_) {};
      notifier.isCoreCompleted = () => false;

      await notifier.restartCore();

      expect(shutdownCalls, 1);
      expect(initCalls, 0);
      expect(container.read(coreStatusProvider), CoreStatus.disconnected);
    });

    test('tryStartCore returns false when reconnect fails', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
          versionProvider.overrideWithBuild((_, _) => 1),
          isStartProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      notifier.shutdownCore = (_) async {};
      notifier.preloadCore = () async => 'core connection timeout';
      notifier.initCoreOverride = () async {
        fail('initCore should not run after connectCore failure');
      };
      notifier.showCoreConnectFailure = (_) {};
      notifier.isCoreCompleted = () => false;

      final result = await notifier.tryStartCore();

      expect(result, isFalse);
    });

    test('restartCore returns false when applyProfile fails after reconnect', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
          versionProvider.overrideWithBuild((_, _) => 1),
          isStartProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      notifier.shutdownCore = (_) async {};
      notifier.preloadCore = () async => '';
      notifier.initCoreOverride = () async {};
      notifier.applyProfileAfterRestart = () async => false;
      notifier.isCoreCompleted = () => false;

      final result = await notifier.restartCore();

      expect(result, isFalse);
    });

    test('requestAdmin keeps tun disabled after successful authorization', () async {
      final container = ProviderContainer(
        overrides: [
          realTunEnableProvider.overrideWithBuild((_, _) => false),
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
          versionProvider.overrideWithBuild((_, _) => 1),
          isStartProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(coreActionProvider.notifier);
      notifier.authorizeCore = () async => AuthorizeCode.success;
      notifier.restartCoreAfterAuthorization = () async => true;

      final result = await notifier.requestAdmin(true);

      expect(result.isError, isTrue);
      expect(container.read(realTunEnableProvider), true);
    });
  });

  group('SetupAction', () {
    test('fallbackCurrentProfile restores original id when all candidates fail', () async {
      final first = Profile.normal(label: 'first');
      final second = Profile.normal(label: 'second');
      final third = Profile.normal(label: 'third');
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => first.id),
          profilesProvider.overrideWith(() => _TestProfiles([first, second, third])),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      notifier.applyProfileForFallback = () async => false;

      await notifier.fallbackCurrentProfileForTest();

      expect(container.read(currentProfileIdProvider), first.id);
    });

    test('start status aborts when tryStartCore fails to reconnect', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      notifier.tryStartCoreForStatusStart = () async => false;

      await notifier.updateStatus(true);

      expect(container.read(runTimeProvider), isNull);
      expect(container.read(coreStatusProvider), CoreStatus.disconnected);
    });

    test('init start clears runtime when applyProfile fails', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      notifier.applyProfileOnInitStart = ({preloadInvoke}) async => false;

      await notifier.updateStatus(true, isInit: true);

      expect(container.read(runTimeProvider), isNull);
    });

    test('init start keeps needInitStatus true when applyProfile fails', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          versionProvider.overrideWithBuild((_, _) => 1),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      final previousNeedInitStatus = globalState.needInitStatus;
      addTearDown(() {
        globalState.needInitStatus = previousNeedInitStatus;
      });
      globalState.needInitStatus = true;
      notifier.applyProfileOnInitStart = ({preloadInvoke}) async => false;

      await notifier.updateStatus(true, isInit: true);

      expect(globalState.needInitStatus, isTrue);
    });

    test('ohos vpn init start does not report connected when listener attach fails', () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          runTimeProvider.overrideWithBuild((_, _) => null),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          versionProvider.overrideWithBuild((_, _) => 1),
          vpnSettingProvider.overrideWithBuild(
            (_, _) => const VpnProps(enable: true),
          ),
          patchClashConfigProvider.overrideWithBuild(
            (_, _) => const PatchClashConfig(),
          ),
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.disconnected),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      final previousNeedInitStatus = globalState.needInitStatus;
      addTearDown(() {
        globalState.needInitStatus = previousNeedInitStatus;
      });
      globalState.needInitStatus = true;
      notifier.startCoreListener = () async => false;

      await notifier.updateStatus(true, isInit: true);

      expect(container.read(runTimeProvider), isNull);
      expect(container.read(coreStatusProvider), CoreStatus.disconnected);
      expect(container.read(isStartProvider), isFalse);
      expect(globalState.needInitStatus, isTrue);
    });

    test('ohos idle startup applies profile to ui core instead of config-only prep', () async {
      final container = ProviderContainer(
        overrides: [
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          profilesProvider.overrideWith(() => _TestProfiles(const [])),
          vpnSettingProvider.overrideWithBuild(
            (_, _) => const VpnProps(enable: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      var applyProfileCalls = 0;
      notifier.isOhosPlatform = () => true;
      notifier.applyProfileForInitIdle = () async {
        applyProfileCalls += 1;
        return true;
      };

      await notifier.initStatus();

      expect(applyProfileCalls, 1);
    });

    test('ohos stopping vpn keeps ui core connected', () async {
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
          runTimeProvider.overrideWithBuild((_, _) => 5000),
          vpnSettingProvider.overrideWithBuild(
            (_, _) => const VpnProps(enable: true),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      notifier.isOhosPlatform = () => true;

      await notifier.updateStatus(false);

      expect(container.read(coreStatusProvider), CoreStatus.connected);
      expect(container.read(isStartProvider), isFalse);
      expect(container.read(runTimeProvider), isNull);
    });

    test('restore failed OHOS VPN stop recovers local running state snapshot', () async {
      final startedAt = DateTime.now().subtract(const Duration(seconds: 5));
      final traffics = FixedList<Traffic>(
        30,
        list: const [Traffic(up: 1, down: 2)],
      );
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
          runTimeProvider.overrideWithBuild((_, _) => 5000),
          trafficsProvider.overrideWithBuild((_, _) => traffics),
          totalTrafficProvider.overrideWithBuild(
            (_, _) => const Traffic(up: 3, down: 4),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      notifier.startTime = startedAt;
      var resumedSyncCoreState = false;
      notifier.resumeAfterFailedOhosVpnStop = ({
        required bool syncCoreState,
      }) async {
        resumedSyncCoreState = syncCoreState;
      };
      notifier.captureOhosVpnStopRollbackStateForTest();

      notifier.startTime = null;
      container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      container.read(runTimeProvider.notifier).value = null;
      container.read(trafficsProvider.notifier).clear();
      container.read(totalTrafficProvider.notifier).value = const Traffic();

      final restored = await notifier.restoreOhosVpnStateAfterFailedStop();

      expect(restored, isTrue);
      expect(notifier.startTime, startedAt);
      expect(resumedSyncCoreState, isTrue);
      expect(container.read(isStartProvider), isTrue);
      expect(container.read(coreStatusProvider), CoreStatus.connected);
      expect(container.read(trafficsProvider).length, 1);
      expect(
        container.read(totalTrafficProvider),
        const Traffic(up: 3, down: 4),
      );
    });

    test('restore failed OHOS VPN stop does not partially restore local running state when resume fails', () async {
      final startedAt = DateTime.now().subtract(const Duration(seconds: 5));
      final traffics = FixedList<Traffic>(
        30,
        list: const [Traffic(up: 1, down: 2)],
      );
      final container = ProviderContainer(
        overrides: [
          coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
          runTimeProvider.overrideWithBuild((_, _) => 5000),
          trafficsProvider.overrideWithBuild((_, _) => traffics),
          totalTrafficProvider.overrideWithBuild(
            (_, _) => const Traffic(up: 3, down: 4),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(setupActionProvider.notifier);
      notifier.startTime = startedAt;
      notifier.resumeAfterFailedOhosVpnStop = ({
        required bool syncCoreState,
      }) async {
        throw StateError('listener attach failed');
      };
      notifier.captureOhosVpnStopRollbackStateForTest();

      notifier.startTime = null;
      container.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
      container.read(runTimeProvider.notifier).value = null;
      container.read(trafficsProvider.notifier).clear();
      container.read(totalTrafficProvider.notifier).value = const Traffic();

      final restored = await notifier.restoreOhosVpnStateAfterFailedStop();

      expect(restored, isFalse);
      expect(notifier.startTime, isNull);
      expect(container.read(isStartProvider), isFalse);
      expect(container.read(coreStatusProvider), CoreStatus.disconnected);
      expect(container.read(runTimeProvider), isNull);
      expect(container.read(trafficsProvider).length, 0);
      expect(container.read(totalTrafficProvider), const Traffic());

      notifier.resumeAfterFailedOhosVpnStop = ({
        required bool syncCoreState,
      }) async {
        fail('stale rollback snapshot should be cleared after a failed restore');
      };
      final restoredAgain = await notifier.restoreOhosVpnStateAfterFailedStop();
      expect(restoredAgain, isFalse);
    });
  });
}

class _TestProfiles extends Profiles {
  final List<Profile> initial;

  _TestProfiles(this.initial);

  @override
  List<Profile> build() => initial;

  @override
  void put(Profile profile) {
    final next = List<Profile>.from(state);
    final index = next.indexWhere((item) => item.id == profile.id);
    if (index == -1) {
      next.add(profile);
    } else {
      next[index] = profile;
    }
    state = next;
  }
}
