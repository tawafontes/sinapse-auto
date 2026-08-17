import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'theme_selection_screen.dart';

class _PermissionItem {
  const _PermissionItem({
    required this.permission,
    required this.icon,
    required this.title,
    required this.description,
    required this.isOptional,
  });

  final Permission permission;
  final IconData icon;
  final String title;
  final String description;
  final bool isOptional;
}

const _permissionItems = [
  _PermissionItem(
    permission: Permission.locationWhenInUse,
    icon: Icons.location_on_outlined,
    title: 'Localização',
    description: 'Necessária para medir a velocidade do veículo.',
    isOptional: false,
  ),
  _PermissionItem(
    permission: Permission.camera,
    icon: Icons.camera_alt_outlined,
    title: 'Câmera',
    description: 'Usada pelo modo dashcam para gravar vídeo.',
    isOptional: false,
  ),
  // Microphone is deliberately NOT requested here (Fase 15): audio is off by
  // default, and is instead requested just-in-time from DashcamSettingsScreen
  // only if/when the user explicitly enables it — never upfront for a
  // feature most installs won't use.
  _PermissionItem(
    permission: Permission.notification,
    icon: Icons.notifications_none,
    title: 'Notificações',
    description: 'Usadas para alertas do aplicativo.',
    isOptional: false,
  ),
];

/// Requests every permission the app can use, all at once, with a short
/// explanation for each. Denying an essential permission never blocks
/// progress — the app is expected to keep working with reduced
/// functionality (e.g. no speed reading without location).
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  final Map<Permission, PermissionStatus> _statuses = {};
  bool _requested = false;
  bool _requesting = false;

  Future<void> _requestAll() async {
    setState(() => _requesting = true);
    final result = await _permissionItems
        .map((item) => item.permission)
        .toList()
        .request();
    setState(() {
      _statuses
        ..clear()
        ..addAll(result);
      _requested = true;
      _requesting = false;
    });
  }

  void _continue() {
    // Sensor/style selection moved out of first-run onboarding — a new user
    // lands on an empty dashboard and adds tools later via its "+" button
    // (or the Settings screen). Onboarding itself just needs a theme.
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ThemeSelectionScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permissões')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'O Synapse Auto usa estas permissões para funcionar melhor. '
                'Você pode negar qualquer uma delas e continuar mesmo assim.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: ListView(
                children: _permissionItems.map((item) {
                  final status = _statuses[item.permission];
                  return ListTile(
                    leading: Icon(item.icon),
                    title: Text(item.title),
                    subtitle: Text(item.description),
                    trailing: _StatusIcon(status: status),
                  );
                }).toList(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _requesting
                          ? null
                          : (_requested ? _continue : _requestAll),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _requested ? 'Continuar' : 'Solicitar permissões',
                        ),
                      ),
                    ),
                  ),
                  if (!_requested)
                    TextButton(
                      onPressed: _requesting ? null : _continue,
                      child: const Text('Pular por agora'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final PermissionStatus? status;

  @override
  Widget build(BuildContext context) {
    if (status == null) {
      return const SizedBox.shrink();
    }
    if (status!.isGranted || status!.isLimited || status!.isProvisional) {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    return Icon(Icons.cancel, color: Theme.of(context).colorScheme.error);
  }
}
