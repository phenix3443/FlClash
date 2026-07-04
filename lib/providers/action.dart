import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yaml/yaml.dart';

part 'generated/action.g.dart';

final _selectedMapMetaValuePattern = RegExp(r'^(剩余流量：|距离下次重置剩余：|套餐到期：)');

bool isInvalidSelectedProxyName(String proxyName) {
  final trimmed = proxyName.trim();
  if (trimmed.isEmpty) {
    return true;
  }
  return _selectedMapMetaValuePattern.hasMatch(trimmed);
}

String? inferGlobalSelection({
  required Map<String, String> selectedMap,
  required Iterable<String> groupNames,
}) {
  final availableNames = groupNames
      .where((name) => name.isNotEmpty && name != GroupName.GLOBAL.name)
      .toSet();
  for (final groupName in selectedMap.keys) {
    if (groupName == GroupName.GLOBAL.name) {
      continue;
    }
    if (availableNames.isEmpty || availableNames.contains(groupName)) {
      return groupName;
    }
  }
  if (availableNames.isNotEmpty) {
    return availableNames.first;
  }
  return null;
}

bool _selectedMapsEqual(Map<String, String> current, Map<String, String> next) {
  if (identical(current, next)) {
    return true;
  }
  if (current.length != next.length) {
    return false;
  }
  for (final entry in current.entries) {
    if (next[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

Map<String, String> sanitizeSelectedMap({
  required List<Group> groups,
  required Map<String, String> selectedMap,
}) {
  if (selectedMap.isEmpty) {
    return selectedMap;
  }

  final sanitized = <String, String>{};
  selectedMap.forEach((groupName, proxyName) {
    if (isInvalidSelectedProxyName(proxyName)) {
      return;
    }
    if (groups.isEmpty) {
      sanitized[groupName] = proxyName;
      return;
    }
    final group = groups.where((item) => item.name == groupName).firstOrNull;
    if (group == null) {
      return;
    }
    final exists = group.all.any((proxy) => proxy.name == proxyName);
    if (exists) {
      sanitized[groupName] = proxyName;
    }
  });
  if (sanitized.length != selectedMap.length) {
    commonPrint.log('[selected-map] sanitized from=$selectedMap to=$sanitized');
  }
  return sanitized;
}

void persistSanitizedSelectedMap(Ref ref, Map<String, String> selectedMap) {
  final currentProfile = ref.read(currentProfileProvider);
  if (currentProfile == null) return;
  if (_selectedMapsEqual(currentProfile.selectedMap, selectedMap)) {
    return;
  }
  commonPrint.log(
    '[selected-map] persist sanitized profile=${currentProfile.id} '
    'from=${currentProfile.selectedMap} to=$selectedMap',
  );
  ref
      .read(profilesProvider.notifier)
      .put(currentProfile.copyWith(selectedMap: selectedMap));
}

bool shouldUseOhosVpnConfigOnly({
  required bool isOhos,
  required bool vpnEnabled,
}) {
  return isOhos && vpnEnabled;
}

bool shouldUseCoreProfileConfigForSetup({
  required bool isOhos,
  required bool applyCore,
}) {
  return !(isOhos && !applyCore);
}

bool resolveUseCoreProfileConfigForSetup({
  required bool? explicitUseCoreProfileConfig,
  required bool isOhos,
  required bool applyCore,
}) {
  return explicitUseCoreProfileConfig ??
      shouldUseCoreProfileConfigForSetup(isOhos: isOhos, applyCore: applyCore);
}

class _OhosVpnStopRollbackState {
  final DateTime? startTime;
  final CoreStatus coreStatus;
  final FixedList<Traffic> traffics;
  final Traffic totalTraffic;

  const _OhosVpnStopRollbackState({
    required this.startTime,
    required this.coreStatus,
    required this.traffics,
    required this.totalTraffic,
  });
}

@Riverpod(keepAlive: true)
class CommonAction extends _$CommonAction {
  @override
  void build() {}

  void updateStart() {
    ref
        .read(setupActionProvider.notifier)
        .updateStatus(!ref.read(isStartProvider));
  }

  void updateSpeedStatistics() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(showTrayTitle: !state.showTrayTitle));
  }

  void updateMode() {
    ref.read(patchClashConfigProvider.notifier).update((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) return state;
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  void updateRunTime() {
    final startTime = ref.read(setupActionProvider.notifier).startTime;
    if (startTime != null) {
      final startTimeStamp = startTime.millisecondsSinceEpoch;
      final nowTimeStamp = DateTime.now().millisecondsSinceEpoch;
      ref.read(runTimeProvider.notifier).value = nowTimeStamp - startTimeStamp;
    } else {
      ref.read(runTimeProvider.notifier).value = null;
    }
  }

  Future<void> updateTraffic() async {
    final onlyStatisticsProxy = ref.read(
      appSettingProvider.select((state) => state.onlyStatisticsProxy),
    );
    final traffic = await coreController.getTraffic(onlyStatisticsProxy);
    ref.read(trafficsProvider.notifier).addTraffic(traffic);
    ref.read(totalTrafficProvider.notifier).value = await coreController
        .getTotalTraffic(onlyStatisticsProxy);
  }

  Future<void> autoCheckUpdate() async {
    final enabled = ref.read(appSettingProvider).autoCheckUpdate;
    commonPrint.log('[auto-check-update] enabled=$enabled');
    if (!enabled) {
      commonPrint.log('[auto-check-update] skip request');
      return;
    }
    commonPrint.log('[auto-check-update] request start');
    final res = await request.checkForUpdate();
    commonPrint.log(
      '[auto-check-update] request done status=${res.status.name}',
    );
    checkUpdateResultHandle(result: res);
  }

  Future<void> checkUpdateResultHandle({
    required CheckForUpdateResult result,
    bool isUser = false,
  }) async {
    if (result.status == CheckForUpdateStatus.failed) {
      if (isUser) {
        globalState.showMessage(
          title: currentAppLocalizations.checkUpdate,
          message: TextSpan(text: currentAppLocalizations.checkUpdateError),
        );
      }
      return;
    }
    if (result.status == CheckForUpdateStatus.upToDate) {
      if (isUser) {
        globalState.showMessage(
          title: currentAppLocalizations.checkUpdate,
          message: TextSpan(text: currentAppLocalizations.checkUpdateLatest),
        );
      }
      return;
    }
    final data = result.data;
    if (data != null) {
      final tagName = data['tag_name'];
      final body = data['body'];
      final submits = utils.parseReleaseBody(body);
      final context = globalState.navigatorKey.currentContext!;
      final textTheme = context.textTheme;
      final res = await globalState.showMessage(
        title: currentAppLocalizations.discoverNewVersion,
        message: TextSpan(
          text: '$tagName \n',
          style: textTheme.headlineSmall,
          children: [
            TextSpan(text: '\n', style: textTheme.bodyMedium),
            for (final submit in submits)
              TextSpan(text: '- $submit \n', style: textTheme.bodyMedium),
          ],
        ),
        confirmText: currentAppLocalizations.goDownload,
        cancelText: isUser ? null : currentAppLocalizations.noLongerRemind,
      );
      if (res == true) {
        launchUrl(Uri.parse('https://github.com/$repository/releases/latest'));
      } else if (!isUser && res == false) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(autoCheckUpdate: false));
      }
    }
  }
}

@Riverpod(keepAlive: true)
class SetupAction extends _$SetupAction {
  Timer? _updateTimer;
  DateTime? startTime;
  _OhosVpnStopRollbackState? _ohosVpnStopRollbackState;
  @visibleForTesting
  Future<void> Function({required bool syncCoreState})?
  resumeAfterFailedOhosVpnStop;
  List<String> _lastProfileGroupNames = const [];

  @visibleForTesting
  Future<bool> Function({VoidCallback? preloadInvoke})? applyProfileOnInitStart;

  @visibleForTesting
  Future<bool> Function()? tryStartCoreForStatusStart;

  @visibleForTesting
  Future<bool> Function()? applyProfileForFallback;

  @visibleForTesting
  Future<bool> Function()? startCoreListener;

  @visibleForTesting
  Future<bool> Function()? applyProfileForInitIdle;

  @visibleForTesting
  bool Function()? isOhosPlatform;

  bool get isStart => startTime != null && startTime!.isBeforeNow;

  @override
  void build() {
    applyProfileOnInitStart ??=
        ({VoidCallback? preloadInvoke}) => applyProfile(
          force: true,
          preloadInvoke: preloadInvoke,
        );
    tryStartCoreForStatusStart ??=
        () => ref.read(coreActionProvider.notifier).tryStartCore(true);
    applyProfileForFallback ??= () => applyProfile(force: true, silence: true);
    startCoreListener ??= () => coreController.startListener();
    applyProfileForInitIdle ??= () => applyProfile(force: true);
    isOhosPlatform ??= () => system.isOhos;
  }

  SetupParams get setupParams => _setupParams;

  Map<String, String> _sanitizeSelectedMap(Map<String, String> selectedMap) {
    final groups = ref.read(groupsProvider);
    return sanitizeSelectedMap(groups: groups, selectedMap: selectedMap);
  }

  Map<String, String> _withGlobalSelectionFallback(
    Map<String, String> selectedMap,
  ) {
    final mode = ref.read(
      patchClashConfigProvider.select((state) => state.mode),
    );
    if (mode != Mode.global || selectedMap.containsKey(GroupName.GLOBAL.name)) {
      return selectedMap;
    }
    final groups = ref.read(groupsProvider);
    final fallback = inferGlobalSelection(
      selectedMap: selectedMap,
      groupNames: groups.isNotEmpty
          ? groups.map((group) => group.name)
          : _lastProfileGroupNames,
    );
    if (fallback == null) {
      return selectedMap;
    }
    final nextSelectedMap = Map<String, String>.from(selectedMap)
      ..[GroupName.GLOBAL.name] = fallback;
    commonPrint.log(
      '[selected-map] inferred GLOBAL fallback=$fallback '
      'from=$selectedMap groups=${groups.map((group) => group.name).join(",")} '
      'profileGroups=${_lastProfileGroupNames.join(",")}',
    );
    return nextSelectedMap;
  }

  SetupParams get _setupParams {
    final selectedMap = _withGlobalSelectionFallback(
      _sanitizeSelectedMap(ref.read(selectedMapProvider)),
    );
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    return SetupParams(selectedMap: selectedMap, testUrl: testUrl);
  }

  Future<Map<String, dynamic>> _getProfileConfigMap(
    int profileId, {
    bool useCore = true,
  }) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    Map<String, dynamic> data;
    if (useCore) {
      data = await coreController.getConfig(profileId);
    } else {
      final profileFile = File(profilePath);
      final content = await profileFile.readAsString();
      final rawYaml = loadYaml(content);
      if (rawYaml is! YamlMap) {
        throw 'profile config is invalid';
      }
      data = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(rawYaml)) as Map<String, dynamic>,
      );
    }
    if (data.containsKey('rule') && !data.containsKey('rules')) {
      data['rules'] = data['rule'];
      data.remove('rule');
    }
    try {
      final rules = (data['rules'] as List? ?? const [])
          .map((item) => item.toString())
          .toList();
      final huaweiRules = rules
          .where(
            (rule) =>
                rule.contains('httpdns.platform.dbankcloud.com') ||
                rule.contains('httpdns-browser.platform.dbankcloud.cn') ||
                rule.contains('browsercfg-drcn.cloud.dbankcloud.cn'),
          )
          .take(12)
          .join(' || ');
      commonPrint.log(
        '[profile-config] profile=$profileId useCore=$useCore path=$profilePath '
        'rulesHead=${rules.take(12).join(" || ")} huaweiRules=$huaweiRules',
      );
    } catch (e) {
      commonPrint.log(
        '[profile-config] profile=$profileId useCore=$useCore path=$profilePath summary failed error=$e',
      );
    }
    return data;
  }

  Future<bool> fullSetup() async {
    if (!ref.read(initProvider)) return false;
    ref.read(delayDataSourceProvider.notifier).value = {};
    final useOhosVpnConfigOnly = shouldUseOhosVpnConfigOnly(
      isOhos: isOhosPlatform!(),
      vpnEnabled: ref.read(vpnStateProvider).vpnProps.enable,
    );
    final applied = useOhosVpnConfigOnly
        ? await prepareProfileConfigOnly(force: true)
        : await applyProfile(force: true);
    ref.read(logsProvider.notifier).value = FixedList(500);
    ref.read(requestsProvider.notifier).value = FixedList(500);
    return applied;
  }

  Future<void> _handleStart({
    bool syncCoreState = true,
  }) async {
    startTime ??= DateTime.now();
    //The local status must be updated when performing the run task
    ref.read(commonActionProvider.notifier).updateRunTime();
    if (syncCoreState) {
      ref.read(commonActionProvider.notifier).updateTraffic();
    }
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      ref.read(commonActionProvider.notifier).updateRunTime();
      if (syncCoreState) {
        ref.read(commonActionProvider.notifier).updateTraffic();
      }
    });
    if (syncCoreState && !ref.read(suspendProvider)) {
      final started = await startCoreListener!();
      if (!started) {
        await handleStop(syncCoreState: false);
        throw StateError('startListener failed');
      }
    }
  }

  Future _updateStartTime() async {
    startTime = await service?.getRunTime();
  }

  Future handleStop({bool syncCoreState = true}) async {
    startTime = null;
    _updateTimer?.cancel();
    _updateTimer = null;
    if (syncCoreState) {
      await coreController.stopListener();
    }
  }

  void _captureOhosVpnStopRollbackState() {
    _ohosVpnStopRollbackState = _OhosVpnStopRollbackState(
      startTime: startTime,
      coreStatus: ref.read(coreStatusProvider),
      traffics: ref.read(trafficsProvider).copyWith(),
      totalTraffic: ref.read(totalTrafficProvider),
    );
  }

  void clearOhosVpnStopRollbackState() {
    _ohosVpnStopRollbackState = null;
  }

  Future<bool> restoreOhosVpnStateAfterFailedStop() async {
    final rollbackState = _ohosVpnStopRollbackState;
    if (rollbackState == null) {
      return false;
    }
    try {
      await (resumeAfterFailedOhosVpnStop ??
          ({required bool syncCoreState}) async {
            await _handleStart(syncCoreState: syncCoreState);
          })(syncCoreState: rollbackState.coreStatus == CoreStatus.connected);
    } catch (error, stackTrace) {
      commonPrint.log(
        '[OHOS-VPN] restore local state after failed stop failed: '
        '$error stack: $stackTrace',
        logLevel: LogLevel.warning,
      );
      clearOhosVpnStopRollbackState();
      return false;
    }
    startTime = rollbackState.startTime;
    ref.read(commonActionProvider.notifier).updateRunTime();
    ref.read(coreStatusProvider.notifier).value = rollbackState.coreStatus;
    ref.read(trafficsProvider.notifier).value = rollbackState.traffics.copyWith();
    ref.read(totalTrafficProvider.notifier).value = rollbackState.totalTraffic;
    clearOhosVpnStopRollbackState();
    return true;
  }

  @visibleForTesting
  void captureOhosVpnStopRollbackStateForTest() {
    _captureOhosVpnStopRollbackState();
  }

  Future<void> initStatus() async {
    if (!globalState.needInitStatus) {
      commonPrint.log('init status cancel');
      return;
    }
    commonPrint.log('init status');
    if (system.isAndroid) {
      await _updateStartTime();
    }
    final status = isStart == true
        ? true
        : ref.read(appSettingProvider).autoRun;
    final useOhosVpnConfigOnly = shouldUseOhosVpnConfigOnly(
      isOhos: isOhosPlatform!(),
      vpnEnabled: ref.read(vpnStateProvider).vpnProps.enable,
    );
    if (status == true) {
      await updateStatus(true, isInit: true);
    } else {
      final applied = useOhosVpnConfigOnly
          ? await applyProfileForInitIdle!()
          : await applyProfile(force: true);
      if (!applied) {
        await _fallbackCurrentProfile(
          useOhosVpnConfigOnly: useOhosVpnConfigOnly,
        );
      }
    }
  }

  Future<void> _fallbackCurrentProfile({
    bool useOhosVpnConfigOnly = false,
  }) async {
    final currentProfileId = ref.read(currentProfileIdProvider);
    final profiles = ref.read(profilesProvider);
    for (final profile in profiles) {
      if (profile.id == currentProfileId) {
        continue;
      }
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
      final applied = useOhosVpnConfigOnly
          ? await applyProfileForInitIdle!()
          : await applyProfileForFallback!();
      if (applied) {
        return;
      }
    }
    ref.read(currentProfileIdProvider.notifier).value = currentProfileId;
  }

  @visibleForTesting
  Future<void> fallbackCurrentProfileForTest({
    bool useOhosVpnConfigOnly = false,
  }) {
    return _fallbackCurrentProfile(
      useOhosVpnConfigOnly: useOhosVpnConfigOnly,
    );
  }

  Future<void> updateStatus(
    bool isStart, {
    bool isInit = false,
    bool captureOhosVpnStopRollbackState = true,
  }) async {
    final useOhosVpnConfigOnly = shouldUseOhosVpnConfigOnly(
      isOhos: isOhosPlatform!(),
      vpnEnabled: ref.read(vpnStateProvider).vpnProps.enable,
    );
    if (isStart) {
      if (!isInit) {
        if (!useOhosVpnConfigOnly) {
          final res = await tryStartCoreForStatusStart!();
          if (res) return;
          if (ref.read(coreStatusProvider) != CoreStatus.connected) {
            ref.read(runTimeProvider.notifier).value = null;
            return;
          }
        }
        if (!ref.read(initProvider)) return;
        if (useOhosVpnConfigOnly) {
          final prepared = await prepareProfileConfigOnly(force: true);
          if (!prepared) {
            ref.read(runTimeProvider.notifier).value = null;
            return;
          }
          await _handleStart();
          // OHOS VPN: the VPN-process core now dials the main app's CoreService
          // socket, so subscribe to it for live status/traffic/connections and
          // reflect the established link in the dashboard status chip.
          ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
        } else {
          await _handleStart();
          applyProfileDebounce(force: true, silence: true);
        }
      } else {
        ref.read(runTimeProvider.notifier).value = 0;
        try {
          if (useOhosVpnConfigOnly) {
            final prepared = await prepareProfileConfigOnly(force: true);
            if (!prepared) {
              ref.read(runTimeProvider.notifier).value = null;
              return;
            }
            await _handleStart();
            // OHOS VPN: subscribe to the now-linked VPN-process core and reflect
            // the established link in the dashboard status chip.
            ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
            globalState.needInitStatus = false;
          } else {
            final applied = await applyProfileOnInitStart!(
              preloadInvoke: () async {
                await _handleStart();
              },
            );
            if (!applied) {
              ref.read(runTimeProvider.notifier).value = null;
              return;
            }
            globalState.needInitStatus = false;
          }
        } catch (_) {
          ref.read(runTimeProvider.notifier).value = null;
        }
      }
    } else {
      if (useOhosVpnConfigOnly &&
          captureOhosVpnStopRollbackState &&
          ref.read(isStartProvider)) {
        _captureOhosVpnStopRollbackState();
      } else if (!captureOhosVpnStopRollbackState) {
        clearOhosVpnStopRollbackState();
      }
      await handleStop(syncCoreState: !useOhosVpnConfigOnly);
      if (useOhosVpnConfigOnly) {
        clearOhosVpnStopRollbackState();
      } else {
        clearOhosVpnStopRollbackState();
        coreController.resetTraffic();
      }
      ref.read(trafficsProvider.notifier).clear();
      ref.read(totalTrafficProvider.notifier).value = const Traffic();
      ref.read(runTimeProvider.notifier).value = null;
      ref.read(checkIpNumProvider.notifier).add();
    }
  }

  Future<void> updateConfigDebounce() async {
    debouncer.call(FunctionTag.updateConfig, () async {
      await globalState.safeRun(() async {
        final updateParams = ref.read(updateParamsProvider);
        final res = await _requestAdmin(updateParams.tun.enable);
        if (res.isError) return;
        final realTunEnable = ref.read(realTunEnableProvider);
        final message = await coreController.updateConfig(
          updateParams.copyWith.tun(enable: realTunEnable),
        );
        if (message.isNotEmpty) throw message;
      });
    });
  }

  void tryCheckIp() {
    final isTimeout = ref.read(
      networkDetectionProvider.select(
        (state) => state.ipInfo == null && state.isLoading == false,
      ),
    );
    if (!isTimeout) return;
    ref.read(checkIpNumProvider.notifier).add();
  }

  void applyProfileDebounce({bool silence = false, bool force = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence, force) {
      applyProfile(silence: silence, force: force);
    }, args: [silence, force]);
  }

  void changeMode(Mode mode) {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(GroupName.GLOBAL.name);
    }
    ref.read(checkIpNumProvider.notifier).add();
  }

  void autoApplyProfile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      applyProfile();
    });
  }

  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    VoidCallback? preloadInvoke,
  }) async {
    return _setupConfig(
      force: force,
      silence: silence,
      preloadInvoke: preloadInvoke,
      onUpdated: () async {
        await ref.read(proxiesActionProvider.notifier).updateGroups();
        await ref.read(providersProvider.notifier).syncProviders();
      },
    );
  }

  Future<bool> prepareProfileConfigOnly({bool force = false}) async {
    return _setupConfig(force: force, silence: true, applyCore: false);
  }

  Future<VM2<String, String>> getProfile({
    required SetupState setupState,
    required PatchClashConfig patchConfig,
    bool useCoreProfileConfig = true,
  }) async {
    final profileId = setupState.profileId;
    if (profileId == null) return const VM2('', '');
    final defaultUA = globalState.packageInfo.providerCompatibleUa;
    final networkVM2 = ref.read(
      networkSettingProvider.select(
        (state) => VM2(state.appendSystemDns, state.routeMode),
      ),
    );
    final overrideDns = ref.read(overrideDnsProvider);
    final appendSystemDns = networkVM2.a;
    final routeMode = networkVM2.b;
    final configMap = await _getProfileConfigMap(
      profileId,
      useCore: useCoreProfileConfig,
    );
    String? scriptContent;
    final List<Rule> addedRules = [];
    final List<ProxyGroup> proxyGroups = [];
    final List<Rule> rules = [];
    if (setupState.overwriteType == OverwriteType.script) {
      scriptContent = await setupState.script?.content;
    } else if (setupState.overwriteType == OverwriteType.standard) {
      addedRules.addAll(setupState.addedRules);
    } else {
      proxyGroups.addAll(setupState.proxyGroups);
      rules.addAll(setupState.rules);
    }
    final realPatchConfig = patchConfig.copyWith(
      tun: patchConfig.tun.getRealTun(routeMode),
    );
    Map<String, dynamic> rawConfig = configMap;
    if (scriptContent?.isNotEmpty == true) {
      rawConfig = await handleEvaluate(scriptContent!, rawConfig);
    }
    final directory = await appPath.profilesPath;
    final res = makeRealProfileTask(
      MakeRealProfileState(
        rules: rules,
        proxyGroups: proxyGroups,
        profilesPath: directory,
        profileId: profileId,
        rawConfig: rawConfig,
        realPatchConfig: realPatchConfig,
        overrideDns: overrideDns,
        appendSystemDns: appendSystemDns,
        addedRules: addedRules,
        defaultUA: defaultUA,
      ),
    );
    return res;
  }

  Future<String> getProfileWithId(int profileId) async {
    try {
      final setupState = await ref.read(setupStateProvider(profileId).future);
      final patchClashConfig = ref.read(patchClashConfigProvider);
      final res = await getProfile(
        setupState: setupState,
        patchConfig: patchClashConfig,
      );
      return res.a;
    } catch (e) {
      globalState.showNotifier(e.toString());
    }
    return '';
  }

  Future<Result<bool>> _requestAdmin(bool enableTun) async {
    final realTunEnable = ref.read(realTunEnableProvider);
    if (enableTun != realTunEnable && realTunEnable == false) {
      final code = await system.authorizeCore();
      switch (code) {
        case AuthorizeCode.success:
          ref.read(realTunEnableProvider.notifier).value = enableTun;
          final restarted = await ref
              .read(coreActionProvider.notifier)
              .restartCore();
          if (!restarted) {
            return Result.error('');
          }
          return Result.error('');
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          enableTun = false;
          break;
      }
    }
    ref.read(realTunEnableProvider.notifier).value = enableTun;
    return Result.success(enableTun);
  }

  Future<bool> _setupConfig({
    bool force = false,
    bool silence = false,
    bool applyCore = true,
    bool? useCoreProfileConfig,
    VoidCallback? preloadInvoke,
    FutureOr Function()? onUpdated,
  }) async {
    var profile = ref.read(currentProfileProvider);
    if (profile == null) {
      commonPrint.log('setup skip: no current profile');
      return false;
    }
    final nextProfile = await profile.checkAndUpdateAndCopy();
    if (nextProfile != null) {
      profile = nextProfile;
      ref.read(profilesProvider.notifier).put(nextProfile);
    }
    commonPrint.log('setup ===> ${profile.id}');
    final patchConfig = ref.read(patchClashConfigProvider);
    final res = await _requestAdmin(patchConfig.tun.enable);
    if (res.isError) return false;
    final realTunEnable = ref.read(realTunEnableProvider);
    final realPatchConfig = patchConfig.copyWith.tun(enable: realTunEnable);
    final setupState = await ref.read(setupStateProvider(profile.id).future);
    final resolvedUseCoreProfileConfig = resolveUseCoreProfileConfigForSetup(
      explicitUseCoreProfileConfig: useCoreProfileConfig,
      isOhos: system.isOhos,
      applyCore: applyCore,
    );
    if (system.isAndroid || system.isOhos) {
      globalState.lastVpnState = ref.read(vpnStateProvider);
    }
    if (system.isAndroid) {
      final sharedState = ref.read(sharedStateProvider);
      preferences.saveShareState(sharedState);
    }
    final vm2 = await getProfile(
      setupState: setupState,
      patchConfig: realPatchConfig,
      useCoreProfileConfig: resolvedUseCoreProfileConfig,
    );
    final yamlString = vm2.a;
    final yamlMd5 = vm2.b;
    try {
      final yamlMap = loadYaml(yamlString);
      if (yamlMap is YamlMap) {
        final raw = jsonDecode(jsonEncode(yamlMap)) as Map<String, dynamic>;
        final proxyGroups = (raw['proxy-groups'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => item['name']?.toString() ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
        _lastProfileGroupNames = proxyGroups;
        final globalUa = raw['global-ua'];
        final dns = Map<String, dynamic>.from(raw['dns'] as Map? ?? const {});
        final tun = Map<String, dynamic>.from(raw['tun'] as Map? ?? const {});
        final proxyProviders = Map<String, dynamic>.from(
          raw['proxy-providers'] ?? const {},
        );
        final providerSummary = proxyProviders.entries
            .map((entry) {
              final value = Map<String, dynamic>.from(
                entry.value as Map? ?? const {},
              );
              return '${entry.key}|${value['type'] ?? ''}|${value['url'] ?? ''}|${value['path'] ?? ''}';
            })
            .join('; ');
        commonPrint.log(
          '[setup-profile] profile=${profile.id} ua=$globalUa '
          'dnsEnable=${dns['enable']} dnsListen=${dns['listen']} '
          'dnsNameserver=${dns['nameserver']} defaultDns=${dns['default-nameserver']} '
          'enhancedMode=${dns['enhanced-mode']} tunDnsHijack=${tun['dns-hijack']} '
          'tunRouteAddress=${tun['route-address']} '
          'groups=${proxyGroups.join(",")} providers=$providerSummary',
        );
        final rules = (raw['rules'] as List? ?? const [])
            .map((item) => item.toString())
            .toList();
        commonPrint.log(
          '[setup-profile] rulesHead=${rules.take(12).join(" || ")}',
        );
        final directHuaweiHttpDnsRules = rules
            .where(
              (rule) =>
                  rule.contains('httpdns.platform.dbankcloud.com') ||
                  rule.contains('httpdns-browser.platform.dbankcloud.cn') ||
                  rule.contains('browsercfg-drcn.cloud.dbankcloud.cn'),
            )
            .take(12)
            .join(' || ');
        commonPrint.log(
          '[setup-profile] huaweiRules=$directHuaweiHttpDnsRules',
        );
      }
    } catch (e) {
      commonPrint.log(
        '[setup-profile] summary failed profile=${profile.id} error=$e',
      );
    }
    if (yamlMd5 == globalState.lastConfigMd5 && force == false) return true;
    final result = await globalState.loadingRun<bool>(
      () async {
        final configFilePath = await appPath.configFilePath;
        await File(configFilePath).safeWriteAsString(yamlString);
        final configFile = File(configFilePath);
        final configExists = await configFile.exists();
        final configLength = configExists ? await configFile.length() : -1;
        commonPrint.log(
          '[setup-profile] wrote config path=$configFilePath '
          'exists=$configExists bytes=$configLength md5=$yamlMd5',
        );
        globalState.lastConfigMd5 = yamlMd5;
        if (!applyCore) {
          commonPrint.log(
            '[setup-profile] skip core setup and only persist config',
          );
          return true;
        }
        final message = await coreController.setupConfig(
          setupState: setupState,
          params: _setupParams,
          preloadInvoke: preloadInvoke,
        );
        if (message.isNotEmpty && !message.endsWith('is empty')) {
          throw message;
        }
        ref.read(checkIpNumProvider.notifier).add();
        await onUpdated?.call();
        return true;
      },
      silence: true,
      tag: !silence ? LoadingTag.proxies : null,
    );
    return result == true;
  }
}

@Riverpod(keepAlive: true)
class BackupAction extends _$BackupAction {
  @override
  void build() {}

  Future<String> backup() async {
    commonPrint.log('[backup-action] backup start');
    final res = await Future.wait([
      database.profilesDao.fileNames().get(),
      database.scriptsDao.fileNames().get(),
    ]);
    final profileFileNames = res[0];
    final scriptFileNames = res[1];
    final configMap = ref.read(configProvider).toJson();
    configMap['version'] = await preferences.getVersion();
    final backupPath = await backupTask(configMap, [
      ...profileFileNames,
      ...scriptFileNames,
    ]);
    commonPrint.log('[backup-action] backup done path=$backupPath');
    return backupPath;
  }

  Future<void> restore(RestoreOption option) async {
    commonPrint.log('[backup-action] restore start option=${option.name}');
    final restoreDirPath = await appPath.restoreDirPath;
    final restoreDir = Directory(restoreDirPath);
    final restoreStrategy = ref.read(
      appSettingProvider.select((state) => state.restoreStrategy),
    );
    final isOverride = restoreStrategy == RestoreStrategy.override;
    try {
      final migrationData = await restoreTask();
      if (!await restoreDir.exists()) {
        throw currentAppLocalizations.restoreException;
      }
      await database.restore(
        migrationData.profiles,
        migrationData.scripts,
        migrationData.rules,
        migrationData.links,
        migrationData.proxyGroups,
        isOverride: isOverride,
      );
      final configMap = migrationData.configMap;
      if (option == RestoreOption.onlyProfiles || configMap == null) return;
      final config = Config.realFromJson(configMap);
      ref.read(patchClashConfigProvider.notifier).value =
          config.patchClashConfig;
      ref.read(appSettingProvider.notifier).value = config.appSettingProps;
      ref.read(currentProfileIdProvider.notifier).value =
          config.currentProfileId;
      ref.read(davSettingProvider.notifier).value = config.davProps;
      ref.read(themeSettingProvider.notifier).value = config.themeProps;
      ref.read(windowSettingProvider.notifier).value = config.windowProps;
      ref.read(vpnSettingProvider.notifier).value = config.vpnProps;
      ref.read(proxiesStyleSettingProvider.notifier).value =
          config.proxiesStyleProps;
      ref.read(overrideDnsProvider.notifier).value = config.overrideDns;
      ref.read(networkSettingProvider.notifier).value = config.networkProps;
      ref.read(hotKeyActionsProvider.notifier).value = config.hotKeyActions;
      await preferences.saveConfig(ref.read(configProvider));
      commonPrint.log(
        '[backup-action] restore persisted config option=${option.name} openLogs=${ref.read(appSettingProvider).openLogs}',
      );
      commonPrint.log(
        '[backup-action] restore applied config option=${option.name}',
      );
      return;
    } finally {
      commonPrint.log('[backup-action] restore cleanup option=${option.name}');
      await restoreDir.safeDelete(recursive: true);
    }
  }
}

@Riverpod(keepAlive: true)
class CoreAction extends _$CoreAction {
  Completer<void>? _pendingConnectCore;

  @visibleForTesting
  Future<String> Function() preloadCore = () => coreController.preload();

  @visibleForTesting
  Future<void> Function(bool isUser) shutdownCore =
      (isUser) => coreController.shutdown(isUser);

  @visibleForTesting
  Future<void> Function()? initCoreOverride;

  @visibleForTesting
  void Function(String message) showCoreConnectFailure =
      globalState.showNotifier;

  @visibleForTesting
  bool Function() isCoreCompleted = () => coreController.isCompleted;

  @visibleForTesting
  FutureOr<bool> Function() isCoreInit = () => coreController.isInit;

  @visibleForTesting
  Future<bool> Function(int version) runCoreInit =
      (version) => coreController.init(version);

  @visibleForTesting
  Future<AuthorizeCode> Function() authorizeCore = () => system.authorizeCore();

  @visibleForTesting
  Future<bool> Function()? restartCoreAfterAuthorization;

  @visibleForTesting
  Future<bool> Function()? applyProfileAfterRestart;

  @override
  void build() {
    restartCoreAfterAuthorization ??= () => restartCore();
    applyProfileAfterRestart ??=
        () => ref.read(setupActionProvider.notifier).applyProfile(force: true);
  }

  Future<void> initCore() async {
    final version = ref.read(versionProvider);
    commonPrint.log('[OHOS-CORE] initCore enter version=$version');
    bool isInit;
    try {
      commonPrint.log('[OHOS-CORE] initCore before isInit');
      final stopwatch = Stopwatch()..start();
      isInit = await isCoreInit();
      stopwatch.stop();
      commonPrint.log(
        '[OHOS-CORE] initCore after isInit value=$isInit elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
    } catch (e, s) {
      commonPrint.log(
        '[OHOS-CORE] initCore isInit threw error=$e stack=$s',
        logLevel: LogLevel.error,
      );
      rethrow;
    }

    if (!isInit) {
      try {
        commonPrint.log('[OHOS-CORE] initCore before init version=$version');
        final stopwatch = Stopwatch()..start();
        final res = await runCoreInit(version);
        stopwatch.stop();
        commonPrint.log(
          '[OHOS-CORE] initCore after init result=$res elapsed=${stopwatch.elapsedMilliseconds}ms',
        );
        if (!res) {
          throw StateError('core init returned false');
        }
      } catch (e, s) {
        commonPrint.log(
          '[OHOS-CORE] initCore init threw error=$e stack=$s',
          logLevel: LogLevel.error,
        );
        rethrow;
      }
    } else {
      commonPrint.log('[OHOS-CORE] initCore skip init and update groups');
      await ref.read(proxiesActionProvider.notifier).updateGroups();
    }
    commonPrint.log('[OHOS-CORE] initCore exit');
  }

  Future<void> connectCore() async {
    final pendingConnectCore = _pendingConnectCore;
    if (pendingConnectCore != null) {
      commonPrint.log('[OHOS-CORE] connectCore join in-flight attempt');
      await pendingConnectCore.future;
      return;
    }

    final completer = Completer<void>();
    _pendingConnectCore = completer;
    ref.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
    commonPrint.log('[OHOS-CORE] connectCore begin');
    try {
      final result = await Future.wait([
        preloadCore(),
        Future.delayed(const Duration(milliseconds: 300)),
      ]);
      final String message = result[0];
      if (message.isNotEmpty) {
        commonPrint.log('[OHOS-CORE] connectCore failed message=$message');
        ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
        showCoreConnectFailure(message);
        return;
      }
      ref.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      commonPrint.log('[OHOS-CORE] connectCore connected');
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_pendingConnectCore, completer)) {
        _pendingConnectCore = null;
      }
    }
  }

  Future<Result<bool>> requestAdmin(bool enableTun) async {
    final realTunEnable = ref.read(realTunEnableProvider);
    if (enableTun != realTunEnable && realTunEnable == false) {
      final code = await authorizeCore();
      switch (code) {
        case AuthorizeCode.success:
          ref.read(realTunEnableProvider.notifier).value = enableTun;
          final restarted = await restartCoreAfterAuthorization!();
          if (!restarted) {
            return Result.error('');
          }
          return Result.error('');
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          enableTun = false;
          break;
      }
    }
    ref.read(realTunEnableProvider.notifier).value = enableTun;
    return Result.success(enableTun);
  }

  Future<bool> restartCore([bool start = false]) async {
    final isDisconnected =
        ref.read(coreStatusProvider) == CoreStatus.disconnected;
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    await shutdownCore(!isDisconnected);
    await connectCore();
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      return false;
    }
    await (initCoreOverride ?? initCore)();
    if (start || ref.read(isStartProvider)) {
      await ref
          .read(setupActionProvider.notifier)
          .updateStatus(true, isInit: true);
    } else {
      final applied = await applyProfileAfterRestart!();
      if (!applied) {
        return false;
      }
    }
    return true;
  }

  Future<bool> tryStartCore([bool start = false]) async {
    if (isCoreCompleted()) return false;
    return restartCore(start);
  }

  void handleCoreDisconnected() {
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
  }
}

@Riverpod(keepAlive: true)
class SystemAction extends _$SystemAction {
  @override
  void build() {}

  Future<List<Package>> getPackages() async {
    if (ref.read(isMobileViewProvider)) {
      await Future.delayed(commonDuration);
    }
    if (ref.read(packagesProvider).isEmpty) {
      ref.read(packagesProvider.notifier).value =
          await app?.getPackages() ?? [];
    }
    return ref.read(packagesProvider);
  }

  Future<void> handleExit([bool needSave = false]) async {
    Future.delayed(const Duration(seconds: 3), () {
      system.exit();
    });
    try {
      await Future.wait([
        if (needSave) preferences.saveConfig(ref.read(configProvider)),
        if (macOS != null) macOS!.updateDns(true),
        if (proxy != null) proxy!.stopProxy(),
        if (tray != null) tray!.destroy(),
      ]);
      await window?.close();
      await coreController.destroy();
      commonPrint.log('exit');
    } finally {
      system.exit();
    }
  }

  Future<void> handleBackOrExit() async {
    if (ref.read(backBlockProvider)) return;
    if (ref.read(appSettingProvider).minimizeOnExit) {
      if (system.isDesktop) {
        await preferences.saveConfig(ref.read(configProvider));
      }
      await system.back();
    } else {
      await handleExit();
    }
  }

  Future<void> updateVisible() async {
    final visible = await window?.isVisible;
    if (visible != null && !visible) {
      window?.show();
    } else {
      window?.hide();
    }
  }

  void updateTun() {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    ref
        .read(networkSettingProvider.notifier)
        .update((state) => state.copyWith(systemProxy: !state.systemProxy));
  }

  void updateAutoLaunch() {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(autoLaunch: !state.autoLaunch));
  }

  Future<void> updateTray() async {
    tray?.update(
      trayState: ref.read(trayStateProvider),
      traffic: ref.read(
        trafficsProvider.select(
          (state) => state.list.safeLast(const Traffic()),
        ),
      ),
    );
  }

  Future<void> updateLocalIp() async {
    ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    ref.read(localIpProvider.notifier).value = await utils.getLocalIpAddress();
  }
}

@Riverpod(keepAlive: true)
class StoreAction extends _$StoreAction {
  @override
  void build() {}

  Future<void> shakingStore() async {
    commonPrint.log('[developer-mode] shakingStore start');
    final profileIds = ref.read(
      profilesProvider.select((state) => state.map((item) => item.id)),
    );
    commonPrint.log(
      '[developer-mode] shakingStore profileIds=${profileIds.join(",")}',
    );
    commonPrint.log(
      '[developer-mode] shakingStore await scriptsDao.query().get()',
    );
    final scripts = await database.scriptsDao.query().get();
    commonPrint.log(
      '[developer-mode] shakingStore scripts loaded count=${scripts.length}',
    );
    final scriptIds = scripts.map((item) => item.id);
    commonPrint.log(
      '[developer-mode] shakingStore scriptIds=${scriptIds.join(",")}',
    );
    final profilesPath = await appPath.profilesPath;
    final scriptsDirPath = await appPath.scriptsDirPath;
    final providersRootPath = await appPath.getProvidersRootPath();
    commonPrint.log(
      '[developer-mode] shakingStore paths profiles=$profilesPath scripts=$scriptsDirPath providers=$providersRootPath',
    );
    commonPrint.log('[developer-mode] shakingStore await shakingProfileTask');
    final pathsToDelete = await shakingProfileTask(
      VM3(
        profileIds,
        scriptIds,
        VM3(profilesPath, scriptsDirPath, providersRootPath),
      ),
    );
    commonPrint.log(
      '[developer-mode] shakingStore pathsToDelete=${pathsToDelete.length}',
    );
    if (pathsToDelete.isNotEmpty) {
      final deleteFutures = pathsToDelete.map((path) async {
        try {
          commonPrint.log(
            '[developer-mode] shakingStore deleteFile start: $path',
          );
          final res = await coreController.deleteFile(path);
          commonPrint.log(
            '[developer-mode] shakingStore deleteFile done: $path res=$res',
          );
          if (res.isNotEmpty) throw res;
        } catch (e) {
          rethrow;
        }
      });
      await Future.wait(deleteFutures);
    }
    commonPrint.log('[developer-mode] shakingStore done');
  }

  void savePreferencesDebounce() {
    debouncer.call(FunctionTag.savePreferences, () async {
      await preferences.saveConfig(ref.read(configProvider));
    });
  }

  Future handleClear() async {
    await preferences.clearPreferences();
    commonPrint.log('clear preferences');
    await database.close();
    await File(await appPath.databasePath).safeDelete(recursive: true);
    final profilesDir = Directory(await appPath.profilesPath);
    commonPrint.log('[developer-mode] clear profiles dir: ${profilesDir.path}');
    await profilesDir.safeClear();
    await preferences.clearPreferences();
    ref.read(patchClashConfigProvider.notifier).value =
        const PatchClashConfig();
    ref.read(appSettingProvider.notifier).value = const AppSettingProps();
    ref.read(currentProfileIdProvider.notifier).value = null;
    ref.read(davSettingProvider.notifier).value = null;
    ref.read(themeSettingProvider.notifier).value = const ThemeProps();
    ref.read(windowSettingProvider.notifier).value = const WindowProps();
    ref.read(vpnSettingProvider.notifier).value = const VpnProps();
    ref.read(proxiesStyleSettingProvider.notifier).value =
        const ProxiesStyleProps();
    ref.read(overrideDnsProvider.notifier).value = false;
    ref.read(networkSettingProvider.notifier).value = const NetworkProps();
    ref.read(hotKeyActionsProvider.notifier).value = [];
    ref.read(excludeSSIDsProvider.notifier).value = [];
    ref.read(profilesProvider.notifier).setAndReorder(const []);
    ref.read(providersProvider.notifier).value = [];
    ref.read(packagesProvider.notifier).value = [];
    ref.read(logsProvider.notifier).value = FixedList(0);
    ref.read(requestsProvider.notifier).value = FixedList(0);
    ref.read(trafficsProvider.notifier).clear();
    ref.read(totalTrafficProvider.notifier).value = const Traffic();
    ref.read(runTimeProvider.notifier).value = null;
    ref.read(localIpProvider.notifier).value = null;
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.dashboard;
    ref.read(coreStatusProvider.notifier).value = CoreStatus.disconnected;
    globalState.needInitStatus = true;
    ref.read(systemActionProvider.notifier).handleExit(false);
  }
}

@Riverpod(keepAlive: true)
class ThemeAction extends _$ThemeAction {
  @override
  void build() {}

  void updateBrightness() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(systemBrightnessProvider.notifier).value =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    });
  }

  void updateViewSize(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(viewSizeProvider.notifier).value = size;
    });
  }
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  @override
  void build() {}

  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    debouncer.call(FunctionTag.changeProxy, (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(groupName: groupName, proxyName: proxyName);
      updateGroupsDebounce();
    }, args: [groupName, proxyName]);
  }

  Future<void> updateGroups() async {
    try {
      commonPrint.log('updateGroups');
      final groups = await retry(
        task: () async {
          final sortType = ref.read(
            proxiesStyleSettingProvider.select((state) => state.sortType),
          );
          final delayMap = ref.read(delayDataSourceProvider);
          final testUrl = ref.read(
            appSettingProvider.select((state) => state.testUrl),
          );
          final selectedMap = sanitizeSelectedMap(
            groups: ref.read(groupsProvider),
            selectedMap: ref.read(
              currentProfileProvider.select(
                (state) => state?.selectedMap ?? {},
              ),
            ),
          );
          return coreController.getProxiesGroups(
            selectedMap: selectedMap,
            sortType: sortType,
            delayMap: delayMap,
            defaultTestUrl: testUrl,
          );
        },
        retryIf: (res) => res.isEmpty,
      );
      ref.read(groupsProvider.notifier).value = groups;
      persistSanitizedSelectedMap(
        ref,
        sanitizeSelectedMap(
          groups: groups,
          selectedMap: ref.read(
            currentProfileProvider.select((state) => state?.selectedMap ?? {}),
          ),
        ),
      );
    } catch (e) {
      commonPrint.log('updateGroups error: $e');
      ref.read(groupsProvider.notifier).value = [];
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    ref.read(delayDataSourceProvider.notifier).setDelay(delay);
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    await coreController.changeProxy(
      ChangeProxyParams(groupName: groupName, proxyName: proxyName),
    );
    if (ref.read(appSettingProvider).closeConnections) {
      await coreController.closeConnections();
    } else {
      await coreController.resetConnections();
    }
    ref.read(checkIpNumProvider.notifier).add();
  }

  Future<String> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    try {
      if (showLoading) {
        ref.read(isUpdatingProvider(provider.updatingKey).notifier).value =
            true;
      }
      final message = await coreController.updateExternalProvider(
        providerName: provider.name,
      );
      if (message.isNotEmpty) return message;
      final updatedProvider = await coreController
          .waitForExternalProviderUpdate(provider);
      ref
          .read(providersProvider.notifier)
          .setProvider(
            updatedProvider ??
                await coreController.getExternalProvider(provider.name),
          );
      return '';
    } finally {
      ref.read(isUpdatingProvider(provider.updatingKey).notifier).value = false;
    }
  }
}

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    if (isInvalidSelectedProxyName(proxyName)) {
      commonPrint.log(
        '[selected-map] reject invalid selection group=$groupName proxy=$proxyName',
      );
      return;
    }
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  Future<void> deleteProfile(int id) async {
    ref.read(profilesProvider.notifier).del(id);
    clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        ref.read(setupActionProvider.notifier).updateStatus(false);
      }
    }
  }

  Future<void> autoUpdateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (!profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(e.toString(), logLevel: LogLevel.warning);
      }
    }
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> updateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) continue;
      await updateProfile(profile);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    try {
      commonPrint.log(
        '[profile-sync-action] begin id=${profile.id} label=${profile.realLabel} showLoading=$showLoading type=${profile.type.name} lastUpdate=${profile.lastUpdateDate?.toIso8601String()}',
      );
      if (showLoading) {
        ref.read(isUpdatingProvider(profile.updatingKey).notifier).value = true;
      }
      ref.read(profilesProvider.notifier).put(profile);
      final newProfile = await profile.update();
      commonPrint.log(
        '[profile-sync-action] updated id=${newProfile.id} label=${newProfile.realLabel} lastUpdate=${newProfile.lastUpdateDate?.toIso8601String()}',
      );
      ref.read(profilesProvider.notifier).put(newProfile);
      if (profile.id == ref.read(currentProfileIdProvider)) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      }
    } finally {
      commonPrint.log(
        '[profile-sync-action] end id=${profile.id} label=${profile.realLabel}',
      );
      ref.read(isUpdatingProvider(profile.updatingKey).notifier).value = false;
    }
  }

  Future<void> addProfileFormFile() async {
    commonPrint.log('[profile-file-import] start');
    final platformFile = await globalState.safeRun(picker.pickerFile);
    final bytes = platformFile?.bytes;
    commonPrint.log(
      '[profile-file-import] picked name=${platformFile?.name} '
      'bytes=${bytes?.length ?? 0} path=${platformFile?.path}',
    );
    if (bytes == null) {
      commonPrint.log('[profile-file-import] result: no-bytes');
      return;
    }
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(label: platformFile?.name).saveFile(bytes);
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      commonPrint.log(
        '[profile-file-import] success: id=${profile.id} '
        'type=${profile.type.name} label=${profile.label}',
      );
      putProfile(profile);
    } else {
      commonPrint.log('[profile-file-import] result: null');
    }
  }

  Future<void> addProfileFormURL(String url) async {
    commonPrint.log('[ohos-profile-url] addProfileFormURL start: $url');
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(url: url).update();
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      commonPrint.log(
        '[ohos-profile-url] addProfileFormURL success: id=${profile.id} type=${profile.type.name} label=${profile.label}',
      );
      putProfile(profile);
    } else {
      commonPrint.log('[ohos-profile-url] addProfileFormURL result: null');
    }
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final providersDirPath = await appPath.getProvidersDirPath(
      profileId.toString(),
    );
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    await coreController.deleteFile(providersDirPath);
  }
}
