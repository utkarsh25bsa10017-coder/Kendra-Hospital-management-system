import 'package:flutter/material.dart';
import 'package:kendra_hms/core/core.dart';
import 'package:kendra_hms/core/data/remote/hub_server.dart';
import 'package:kendra_hms/core/data/remote/remote_store.dart';
import 'package:kendra_hms/core/services/device_config.dart';
import 'package:kendra_hms/core/setup/setup_service.dart';

import 'admin_widgets.dart';

/// Sharing this computer's data with other devices on the hospital network,
/// or (on a connected device) the link to the hub.
class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return PageScaffold(
      title: 'Network & devices',
      subtitle: app.remote != null
          ? 'This device works on the data kept on the hospital\'s main computer'
          : 'Let reception PCs, doctors\' laptops and tablets on the same Wi-Fi or LAN use this computer\'s data',
      body: app.remote != null ? const _ClientView() : const _HubView(),
    );
  }
}

class _HubView extends StatefulWidget {
  const _HubView();

  @override
  State<_HubView> createState() => _HubViewState();
}

class _HubViewState extends State<_HubView> {
  List<String>? _addresses;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    List<String> a;
    try {
      a = rankAddresses(await HubServer.localAddresses());
    } catch (_) {
      a = const [];
    }
    if (mounted) setState(() => _addresses = a);
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (success != null && mounted) context.toast(success);
    } catch (e) {
      if (mounted) context.toast('Could not change sharing: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    _loadAddresses();
  }

  Future<void> _setSharing(bool on) async {
    final app = context.app;
    if (on) {
      await _run(app.startHub, success: 'Sharing is on. Other devices can connect now.');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'Stop sharing?',
      message: 'Every other device loses its connection until you switch sharing on again. '
          'Nobody on those devices can work in Kendra meanwhile.',
      confirmLabel: 'Stop sharing',
      destructive: true,
    );
    if (ok && mounted) await _run(app.stopHub, success: 'Sharing is off. Only this computer can use the data now.');
  }

  Future<void> _newKey() async {
    final ok = await confirmDialog(
      context,
      title: 'Make a new network key?',
      message: 'Every connected device stops working until someone enters the new key on it. '
          'Do this if the key may have been seen by someone outside the hospital.',
      confirmLabel: 'Make a new key',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final app = context.app;
    await _run(() async {
      final wasOn = app.hub?.running ?? false;
      if (wasOn) await app.stopHub();
      app.config.networkKey = newNetworkKey();
      await app.config.save();
      if (wasOn) await app.startHub();
      await app.db.audit('network_key_changed');
    }, success: 'New network key ready. Enter it on each device.');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final hub = app.hub;
    final sharing = hub?.running ?? false;
    final port = app.config.hubPort;
    final key = app.config.networkKey;
    final addresses = _addresses;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (app.isDemo) ...[
          const NoticeBanner(
            icon: Icons.science_outlined,
            tone: Tone.warning,
            title: 'This is the demo hospital',
            message: 'You can share the demo too, to try Kendra on a tablet or a second computer. '
                'Its sample data is kept apart from your real hospital.',
          ),
          Gap.v16,
        ],
        SectionCard(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: sharing,
            onChanged: _busy ? null : _setSharing,
            secondary: Icon(sharing ? Icons.wifi_tethering : Icons.wifi_tethering_off,
                color: sharing ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant),
            title: Text(sharing ? 'Sharing with other devices' : 'Not shared — only this computer uses the data',
                style: theme.textTheme.titleMedium),
            subtitle: Text(
              sharing
                  ? 'This computer is the hospital\'s hub. Keep it switched on during working hours. '
                      'Nothing goes over the internet.'
                  : 'Switch on to let other devices on the hospital Wi-Fi or LAN connect. Nothing goes over the internet.',
            ),
          ),
        ),
        Gap.v16,
        if (sharing) ...[
          TourAnchor(
            id: 'admin.network_details',
            child: SectionCard(
              title: 'Type these on the other device',
              subtitle: 'The address, the port and the network key',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ResponsiveGrid(minWidth: 240, maxColumns: 3, spacing: Gap.md, children: [
                    if (addresses == null)
                      const BigValue(label: 'Address', value: '…', copyable: false)
                    else if (addresses.isEmpty)
                      const BigValue(
                          label: 'Address',
                          value: 'No network',
                          copyable: false,
                          caption: 'Connect this computer to the hospital Wi-Fi or LAN')
                    else
                      BigValue(label: 'Address', value: addresses.first),
                    BigValue(label: 'Port', value: '$port'),
                    BigValue(label: 'Network key', value: key ?? '—'),
                  ]),
                  if ((addresses?.length ?? 0) > 1) ...[
                    Gap.v12,
                    Text(
                      'If that address does not work, try another address of this computer: '
                      '${addresses!.skip(1).take(5).join(', ')}. Use the one that starts like the other device\'s own '
                      'address (for example 192.168.1.…).',
                      style: muted,
                    ),
                  ],
                  const Divider(height: 32),
                  ActionRow(
                    icon: Icons.key_outlined,
                    title: 'New network key',
                    message: 'If the key may have been seen by someone outside the hospital. '
                        'Every device then needs the new key.',
                    button: OutlinedButton(onPressed: _busy ? null : _newKey, child: const Text('New network key')),
                  ),
                ],
              ),
            ),
          ),
          Gap.v16,
          SectionCard(
            title: 'Connected devices',
            subtitle: 'Devices signed in through this computer in the last 12 hours',
            child: ValueListenableBuilder<List<ConnectedDevice>>(
              valueListenable: hub!.devices,
              builder: (context, devices, _) => devices.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                      child: Text('No other device is connected right now.', style: muted),
                    )
                  : DataList<ConnectedDevice>(
                      items: devices,
                      leading: (d) => const Icon(Icons.devices_other_outlined),
                      title: (d) => d.deviceName,
                      subtitle: (d) => '${d.userName} · ${d.address} · ${formatRelative(d.lastSeen)}',
                      columns: [
                        ListColumn('Device', (d) => Text(d.deviceName), flex: 3),
                        ListColumn('Address', (d) => Text(d.address), flex: 2),
                        ListColumn('Signed in as', (d) => Text(d.userName), flex: 3),
                        ListColumn('Last seen', (d) => Text(formatRelative(d.lastSeen)), flex: 2),
                      ],
                    ),
            ),
          ),
          Gap.v16,
        ],
        SectionCard(
          title: 'Connect another device',
          subtitle: sharing ? 'Takes about two minutes per device' : 'Switch sharing on first',
          child: const _Steps(steps: [
            ('Install Kendra', 'On the reception PC, laptop or Android tablet, install Kendra and open it.'),
            ('Choose "Connect to my hospital"', 'It is on the first screen Kendra shows.'),
            ('Type the address and network key', 'Copy them exactly from the box above. Both devices must be on '
                'the same Wi-Fi or LAN.'),
            ('Name the device and sign in', 'For example "Reception 2". Each person then signs in with their own '
                'username.'),
          ]),
        ),
        Gap.v16,
        Text(
          'Tip: ask whoever looks after your router to give this computer a fixed address, '
          'so devices do not need setting up again after a restart.',
          style: muted,
        ),
      ],
    );
  }
}

/// Local network addresses first (192.168.x, then 10.x, then 172.16–31.x),
/// since those are the ones other devices in the hospital can reach.
List<String> rankAddresses(List<String> all) {
  int rank(String a) {
    final p = a.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.contains(null)) return 9;
    if (p[0] == 192 && p[1] == 168) return 0;
    if (p[0] == 10) return 1;
    if (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31) return 2;
    if (p[0] == 169 && p[1] == 254) return 8;
    return 5;
  }

  final out = {...all}.toList();
  final order = {for (final (i, a) in out.indexed) a: i};
  out.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : order[a]!.compareTo(order[b]!);
  });
  return out;
}

class _Steps extends StatelessWidget {
  const _Steps({required this.steps});
  final List<(String, String)> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ResponsiveGrid(
      minWidth: 230,
      maxColumns: 4,
      children: [
        for (final (i, (title, body)) in steps.indexed)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: cs.primaryContainer,
                child: Text('${i + 1}',
                    style: theme.textTheme.labelLarge?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
              ),
              Gap.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    Gap.v4,
                    Text(body, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ClientView extends StatelessWidget {
  const _ClientView();

  Future<void> _disconnect(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      title: 'Disconnect this device?',
      message: 'This device forgets the hub and goes back to the first screen. No hospital data is lost; '
          'it all stays on the main computer. You need the address and network key to connect again.',
      confirmLabel: 'Disconnect',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final app = context.app;
    await SetupService.disconnectClient(app);
    await app.requestRestart?.call();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final remote = app.remote!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ValueListenableBuilder<HubLink>(
          valueListenable: remote.link,
          builder: (context, link, _) => switch (link) {
            HubLink.online => const NoticeBanner(
                icon: Icons.cloud_done_outlined,
                tone: Tone.success,
                title: 'Connected to the hub',
                message: 'Changes made here appear on every other device straight away.'),
            HubLink.connecting => const NoticeBanner(
                icon: Icons.sync,
                title: 'Connecting…',
                message: 'Looking for the main computer on the network.'),
            HubLink.offline => NoticeBanner(
                icon: Icons.cloud_off_outlined,
                tone: Tone.danger,
                title: 'Cannot reach the hub',
                message: 'Check that the main computer is switched on and that this device is on the hospital '
                    'Wi-Fi. Kendra keeps trying by itself.',
                action: FilledButton(onPressed: remote.reconnectNow, child: const Text('Reconnect'))),
          },
        ),
        Gap.v16,
        SectionCard(
          title: 'This device',
          child: InfoGrid([
            ('Hub address', app.config.hubUrl ?? '—'),
            ('Device name', app.config.deviceName),
            ('Hospital', app.settings.hospitalName),
          ]),
        ),
        Gap.v16,
        SectionCard(
          title: 'Connection',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ActionRow(
                icon: Icons.sync,
                title: 'Reconnect now',
                message: 'Try the hub again straight away instead of waiting for the next automatic attempt.',
                button: OutlinedButton(onPressed: remote.reconnectNow, child: const Text('Reconnect')),
              ),
              const Divider(height: 32),
              ActionRow(
                icon: Icons.link_off,
                title: 'Disconnect this device',
                message: 'For a device that moves to another hospital or is being replaced.',
                button: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: () => _disconnect(context),
                  child: const Text('Disconnect'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
