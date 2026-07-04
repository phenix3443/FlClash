import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animations/animations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'database/database.dart';
import 'enum/enum.dart';
import 'l10n/l10n.dart';
import 'models/models.dart';
import 'plugins/app.dart';
import 'providers/providers.dart';

@visibleForTesting
Future<void> connectUiCoreTransport(ProviderContainer container) async {
  await container.read(coreActionProvider.notifier).connectCore();
}

@visibleForTesting
Future<void> Function(ProviderContainer container)? runStartupInitStatus =
    (container) => container.read(setupActionProvider.notifier).initStatus();

@visibleForTesting
Future<bool> Function(ProviderContainer container)? runOhosUiCorePostVpnStopSync =
    (container) => container
        .read(setupActionProvider.notifier)
        .applyProfile(force: true, silence: true);

@visibleForTesting
Future<void> runUiCoreStartupSequence(ProviderContainer container) async {
  await connectUiCoreTransport(container);
  if (container.read(coreStatusProvider) != CoreStatus.connected) {
    return;
  }
  await container.read(coreActionProvider.notifier).initCore();
  await runStartupInitStatus?.call(container);
}

@visibleForTesting
Future<bool?> Function()? stopPendingDebugVpnAfterFailedInitStart = () async {
  return await app?.stopVpn();
};

@visibleForTesting
typedef PendingDebugVpnStartFinalizationResult =
    ({bool finalized, String? failureMessage});

@visibleForTesting
Future<PendingDebugVpnStartFinalizationResult> finalizePendingDebugVpnStart(
  ProviderContainer container,
) async {
  await container.read(setupActionProvider.notifier).updateStatus(
    true,
    isInit: true,
  );
  final started = container.read(isStartProvider);
  if (started) {
    return (finalized: true, failureMessage: null);
  }
  try {
    final stopped = await stopPendingDebugVpnAfterFailedInitStart?.call();
    commonPrint.log(
      '[OHOS-DEBUG-VPN] rollback native start after init failure stopped=$stopped',
      logLevel: stopped == true ? LogLevel.info : LogLevel.warning,
    );
    return (
      finalized: false,
      failureMessage: stopped == true
          ? 'VPN 启动失败'
          : formatOhosPendingDebugVpnRollbackFailure('VPN 停止失败'),
    );
  } on PlatformException catch (error) {
    final stopFailureMessage = formatOhosVpnStopError(error);
    commonPrint.log(
      '[OHOS-DEBUG-VPN] rollback native start after init failure failed: '
      '$stopFailureMessage',
      logLevel: LogLevel.warning,
    );
    return (
      finalized: false,
      failureMessage: formatOhosPendingDebugVpnRollbackFailure(
        stopFailureMessage,
      ),
    );
  }
}

@visibleForTesting
void applyPendingDebugVpnStartSettings(
  ProviderContainer container, {
  required String? stack,
  required bool ipv6,
}) {
  if (stack != null && stack.isNotEmpty) {
    final currentStack = container.read(
      patchClashConfigProvider.select((state) => state.tun.stack),
    );
    final nextStack = TunStack.values.firstWhere(
      (item) => item.name == stack,
      orElse: () => currentStack,
    );
    container
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith.tun(stack: nextStack));
  }
  container
      .read(vpnSettingProvider.notifier)
      .update((state) => state.copyWith(enable: true, ipv6: ipv6));
}

bool shouldSkipOhosUiCoreStartup(ProviderContainer container) {
  return shouldUseOhosVpnConfigOnly(
    isOhos: system.isOhos,
    vpnEnabled: container.read(vpnStateProvider).vpnProps.enable,
  );
}

@visibleForTesting
Future<void> runSkippedOhosUiCoreStartupSequence(
  ProviderContainer container, {
  bool? isOhosOverride,
}) async {
  final isOhos = isOhosOverride ?? system.isOhos;
  final vpnEnabled = container.read(vpnStateProvider).vpnProps.enable;
  if (!shouldUseOhosVpnConfigOnly(isOhos: isOhos, vpnEnabled: vpnEnabled)) {
    return;
  }
  await connectUiCoreTransport(container);
  if (container.read(coreStatusProvider) != CoreStatus.connected) {
    return;
  }
  await container.read(coreActionProvider.notifier).initCore();
  await runStartupInitStatus?.call(container);
}

Future<void> reconnectOhosUiCoreAfterVpnStop(ProviderContainer container) async {
  await connectUiCoreTransport(container);
  if (container.read(coreStatusProvider) != CoreStatus.connected) {
    return;
  }
  await container.read(coreActionProvider.notifier).initCore();
  await runOhosUiCorePostVpnStopSync?.call(container);
}

class GlobalState {
  static GlobalState? _instance;
  final navigatorKey = GlobalKey<NavigatorState>();
  bool isPre = true;
  late final String coreSHA256;
  late final PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  late ProviderContainer container;
  bool needInitStatus = true;

  // ignore: deprecated_member_use
  CorePalette? corePalette;
  String? lastConfigMd5;
  VpnState? lastVpnState;
  bool isAttach = false;
  Future<void> _pendingOhosDebugVpnStart = Future.value();
  bool _ohosPendingDebugVpnStartReady = false;
  bool _isHandlingOhosPendingDebugVpnStart = false;

  GlobalState._internal();

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  bool get isHandlingOhosPendingDebugVpnStart =>
      _isHandlingOhosPendingDebugVpnStart;

  Future<ProviderContainer> init(int version) async {
    coreSHA256 = const String.fromEnvironment('CORE_SHA256');
    isPre = const String.fromEnvironment('APP_ENV') != 'stable';
    await _initDynamicColor();
    return _initData(version);
  }

  Future<void> _initDynamicColor() async {
    accentColor = const Color(defaultPrimaryColor);
    if (system.isOhos) {
      return;
    }
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor =
          await DynamicColorPlugin.getAccentColor() ??
          const Color(defaultPrimaryColor);
    } catch (_) {}
  }

  String get ua => container
      .read(patchClashConfigProvider.select((state) => state.globalUa))
      .takeFirstValid([packageInfo.providerCompatibleUa]);

  BuildContext get _context => navigatorKey.currentContext!;

  Future<ProviderContainer> _initData(int version) async {
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: const Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    packageInfo = await system.getPackageInfo();
    final configMap = await preferences.getConfigMap();
    final config = await migration.migrationIfNeeded(
      configMap,
      sync: (data) async {
        final newConfigMap = data.configMap;
        final config = Config.realFromJson(newConfigMap);
        await Future.wait([
          database.restore(
            data.profiles,
            data.scripts,
            data.rules,
            data.links,
            data.proxyGroups,
          ),
          preferences.saveConfig(config),
        ]);
        return config;
      },
    );
    final configOverrides = buildConfigOverrides(config);
    container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    final profiles = await database.profilesDao.query().get();
    container.read(profilesProvider.notifier).setAndReorder(profiles);
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSettingProps.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    await window?.init(version, config.windowProps);
    return container;
  }

  Future<T?> loadingRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    required LoadingTag? tag,
    bool silence = false,
  }) async {
    return globalState.safeRun(
      futureFunction,
      silence: silence,
      title: title,
      onStart: () {
        if (tag != null) {
          container.read(loadingProvider(tag).notifier).start();
        }
      },
      onEnd: () {
        if (tag != null) {
          container.read(loadingProvider(tag).notifier).stop();
        }
      },
    );
  }

  Future<T?> safeRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    VoidCallback? onStart,
    VoidCallback? onEnd,
    bool silence = true,
  }) async {
    try {
      onStart?.call();
      return await futureFunction();
    } catch (e, s) {
      commonPrint.log('$title ===> $e, $s', logLevel: LogLevel.warning);
      if (silence) {
        showNotifier(e.toString());
      } else {
        showMessage(
          title: title ?? currentAppLocalizations.tip,
          message: TextSpan(text: e.toString()),
        );
      }
      return null;
    } finally {
      onEnd?.call();
    }
  }

  Future<bool?> showMessage({
    required InlineSpan message,
    BuildContext? context,
    String? title,
    String? confirmText,
    String? cancelText,
    bool cancelable = true,
    bool? dismissible,
  }) async {
    return showCommonDialog<bool>(
      context: context,
      dismissible: dismissible,
      child: Builder(
        builder: (context) {
          final appLocalizations = context.appLocalizations;
          return CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(cancelText ?? appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              ),
            ],
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.labelLarge,
                    children: [message],
                  ),
                  style: const TextStyle(overflow: TextOverflow.visible),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<bool?> showAllUpdatingMessagesDialog(
    List<UpdatingMessage> messages,
  ) async {
    return showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          final appLocalizations = currentAppLocalizations;
          return CommonDialog(
            padding: EdgeInsets.zero,
            title: appLocalizations.tip,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(appLocalizations.confirm),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                itemBuilder: (_, index) {
                  final message = messages[index];
                  return ListItem(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    title: Text(message.label),
                    subtitle: Text(message.message),
                  );
                },
                itemCount: messages.length,
                separatorBuilder: (_, _) => const Divider(height: 0),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<T?> showCommonDialog<T>({
    required Widget child,
    BuildContext? context,
    bool? dismissible,
    bool filter = true,
  }) async {
    return showModal<T>(
      useRootNavigator: false,
      context: context ?? globalState.navigatorKey.currentContext!,
      configuration: FadeScaleTransitionConfiguration(
        barrierColor: Colors.black38,
        barrierDismissible: dismissible ?? true,
      ),
      builder: (_) => child,
      filter: filter ? commonFilter : null,
    );
  }

  void showNotifier(String text, {MessageActionState? actionState}) {
    if (text.isEmpty) {
      return;
    }
    navigatorKey.currentContext?.showNotifier(text, actionState: actionState);
  }

  Future<void> openUrl(String url) async {
    commonPrint.log('[external-url] prompt url=$url');
    final res = await showMessage(
      message: TextSpan(text: url),
      title: currentAppLocalizations.externalLink,
      confirmText: currentAppLocalizations.go,
    );
    commonPrint.log('[external-url] prompt result url=$url confirmed=$res');
    if (res != true) {
      return;
    }
    if (system.isOhos) {
      final success = await app?.openExternalUrl(url) ?? false;
      commonPrint.log(
        '[external-url] ohos open result url=$url success=$success',
      );
      if (!success) {
        showNotifier('打开外部链接失败');
      }
      return;
    }
    launchUrl(Uri.parse(url));
  }

  Future<void> attach() async {
    if (isAttach == true) {
      return;
    }
    await _initApp();
    isAttach = true;
  }

  Future<void> _initApp() async {
    FlutterError.onError = (details) {
      commonPrint.log(
        'exception: ${details.exception} stack: ${details.stack}',
        logLevel: LogLevel.warning,
      );
    };
    container.read(systemActionProvider.notifier).updateTray();
    if (!shouldSkipOhosUiCoreStartup(container)) {
      container.read(profilesActionProvider.notifier).autoUpdateProfiles();
    } else {}
    container.read(commonActionProvider.notifier).autoCheckUpdate();
    autoLaunch?.updateStatus(container.read(appSettingProvider).autoLaunch);
    if (!container.read(appSettingProvider).silentLaunch) {
      window?.show();
    } else {
      window?.hide();
    }
    await _handleFailedPreference();
    await _handlerDisclaimer();
    await _showCrashlyticsTip();
    if (system.isOhos) {
      await appPath.initOhosPaths();
      await app?.updatePendingDebugVpnStartListenerReady(false);
      app?.onPendingDebugVpnStart = (pending) async {
        if (!_ohosPendingDebugVpnStartReady) {
          throw MissingPluginException();
        }
        final currentPendingDebugVpnStart = _pendingOhosDebugVpnStart.then((_) async {
          await _handlePendingDebugVpnStart(pending);
        });
        _pendingOhosDebugVpnStart = currentPendingDebugVpnStart.catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          commonPrint.log(
            '[OHOS-DEBUG-VPN] hot pending start failed: $error stack: $stackTrace',
            logLevel: LogLevel.warning,
          );
        });
        await currentPendingDebugVpnStart;
      };
    }
    final handledPendingDebugVpn = await _handlePendingDebugVpnStart();
    final skipOhosUiCoreStartup = shouldSkipOhosUiCoreStartup(container);
    if (!handledPendingDebugVpn && !skipOhosUiCoreStartup) {
      await runUiCoreStartupSequence(container);
    } else {
      if (!handledPendingDebugVpn && skipOhosUiCoreStartup) {
        await runSkippedOhosUiCoreStartupSequence(container);
      } else {
        await runStartupInitStatus?.call(container);
      }
    }
    _ohosPendingDebugVpnStartReady = true;
    await app?.updatePendingDebugVpnStartListenerReady(true);
    container.read(initProvider.notifier).value = true;
    permissions.check();
  }

  Future<bool> _handlePendingDebugVpnStart([
    Map<String, dynamic>? pending,
  ]) async {
    if (!system.isOhos) {
      return false;
    }
    final currentPending = pending ?? await app?.consumePendingDebugVpnStart();
    if (currentPending == null) {
      return false;
    }
    final stack = currentPending['stack']?.toString();
    final ipv6 = currentPending['ipv6'] == true;
    _isHandlingOhosPendingDebugVpnStart = true;
    try {
      applyPendingDebugVpnStartSettings(
        container,
        stack: stack,
        ipv6: ipv6,
      );
      final prepared = await container
          .read(setupActionProvider.notifier)
          .prepareProfileConfigOnly(force: true);
      if (!prepared) {
        const message = 'VPN 启动失败';
        commonPrint.log(
          '[OHOS-DEBUG-VPN] prepare profile failed before native start',
          logLevel: LogLevel.warning,
        );
        showNotifier(message);
        return false;
      }
      final vpnState = container.read(vpnStateProvider);
      final setupParams = container
          .read(setupActionProvider.notifier)
          .setupParams;
      final homeDir = await appPath.homeDirPath;
      try {
        final started = await app?.startVpn(
          stack: vpnState.stack.name,
          ipv6: vpnState.vpnProps.ipv6,
          initParamsJson: json.encode({
            'home-dir': homeDir,
            'version': container.read(versionProvider),
          }),
          setupParamsJson: json.encode(setupParams.toJson()),
          coreSocketPath: unixSocketPath,
        );
        if (started != true) {
          const message = 'VPN 启动失败';
          commonPrint.log(
            '[OHOS-DEBUG-VPN] direct start did not return true',
            logLevel: LogLevel.warning,
          );
          showNotifier(message);
          return false;
        }
        final finalizationResult = await finalizePendingDebugVpnStart(container);
        if (!finalizationResult.finalized) {
          final message = finalizationResult.failureMessage ?? 'VPN 启动失败';
          commonPrint.log(
            '[OHOS-DEBUG-VPN] finalization failed after native start: $message',
            logLevel: LogLevel.warning,
          );
          showNotifier(message);
        }
        return finalizationResult.finalized;
      } on PlatformException catch (error) {
        final message = formatOhosVpnStartError(error);
        commonPrint.log(
          '[OHOS-DEBUG-VPN] direct start failed: $message',
          logLevel: LogLevel.warning,
        );
        showNotifier(message);
        return false;
      }
    } finally {
      _isHandlingOhosPendingDebugVpnStart = false;
    }
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) return;
    final res = await showMessage(
      title: currentAppLocalizations.tip,
      message: TextSpan(text: currentAppLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    await container.read(systemActionProvider.notifier).handleExit();
  }

  Future<bool> showDisclaimer() async {
    return await showCommonDialog<bool>(
          dismissible: false,
          child: CommonDialog(
            title: currentAppLocalizations.disclaimer,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(_context).pop<bool>(false);
                },
                child: Text(currentAppLocalizations.exit),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(_context).pop<bool>(true);
                },
                child: Text(currentAppLocalizations.agree),
              ),
            ],
            child: Text(currentAppLocalizations.disclaimerDesc),
          ),
        ) ??
        false;
  }

  Future<void> _showCrashlyticsTip() async {
    if (!system.isAndroid || system.isOhos) return;
    if (container.read(
      appSettingProvider.select((state) => state.crashlyticsTip),
    )) {
      return;
    }
    await showMessage(
      title: currentAppLocalizations.dataCollectionTip,
      cancelable: false,
      message: TextSpan(text: currentAppLocalizations.dataCollectionContent),
    );
    container
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(crashlyticsTip: true));
  }

  Future<void> _handlerDisclaimer() async {
    if (system.isOhos) {
      container
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(disclaimerAccepted: true));
      return;
    }
    if (container.read(
      appSettingProvider.select((state) => state.disclaimerAccepted),
    )) {
      return;
    }
    final isDisclaimerAccepted = await showDisclaimer();
    if (!isDisclaimerAccepted) {
      await container.read(systemActionProvider.notifier).handleExit();
    }
    container
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(disclaimerAccepted: true));
  }
}

final globalState = GlobalState();
