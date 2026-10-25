import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:steam_flow/l10n/app_localizations.dart';
import 'package:steam_flow/models/lan_models.dart';
import 'package:steam_flow/providers/lan_provider.dart';
import 'package:steam_flow/providers/settings_provider.dart';
import 'package:steam_flow/screens/remote_videos_screen.dart';
import 'package:steam_flow/services/lan_client_service.dart';

/// 远程设备上的共享文件夹列表。
///
/// 点按文件夹即可浏览其中的视频；右侧按钮把它添加为本机持久化的共享源。
class RemoteBrowserScreen extends StatefulWidget {
  final LanDevice device;

  /// 选择模式：点击文件夹后加入/移出共享源，而不是浏览视频
  final bool selectMode;

  const RemoteBrowserScreen({
    super.key,
    required this.device,
    this.selectMode = false,
  });

  @override
  State<RemoteBrowserScreen> createState() => _RemoteBrowserScreenState();
}

class _RemoteBrowserScreenState extends State<RemoteBrowserScreen> {
  List<RemoteFolder>? _folders;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final folders = await LanClientService.instance.fetchFolders(widget.device);
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _loading = false;
    });
  }

  Future<void> _addSource(RemoteFolder folder) async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final ref = SharedFolderRef(
      deviceId: widget.device.id,
      deviceName: widget.device.name,
      host: widget.device.host,
      port: widget.device.port,
      folderId: folder.id,
      folderName: folder.name,
      videoCount: folder.videoCount,
    );
    settings.addSharedFolder(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).lanAdded),
        duration: const Duration(seconds: 2),
      ),
    );
    await lan.probeSharedDevices([ref]);
    if (!mounted) return;
    await lan.loadSharedFolderCovers([ref]);
  }

  /// 选择模式下切换某个共享文件夹的添加状态
  Future<void> _toggleSelection(RemoteFolder folder, bool selected) async {
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final lan = Provider.of<LanProvider>(context, listen: false);
    final key = '${widget.device.id}/${folder.id}';
    if (selected) {
      settings.removeSharedFolder(key);
      return;
    }
    final ref = SharedFolderRef(
      deviceId: widget.device.id,
      deviceName: widget.device.name,
      host: widget.device.host,
      port: widget.device.port,
      folderId: folder.id,
      folderName: folder.name,
      videoCount: folder.videoCount,
    );
    settings.addSharedFolder(ref);
    if (!mounted) return;
    await lan.probeSharedDevices([ref]);
    if (!mounted) return;
    await lan.loadSharedFolderCovers([ref]);
  }

  void _openFolder(RemoteFolder folder) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RemoteVideosScreen(
          device: widget.device,
          folderId: folder.id,
          folderName: folder.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final settings = Provider.of<SettingsProvider>(context, listen: true);
    final folders = _folders;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name, overflow: TextOverflow.ellipsis),
        centerTitle: true,
        backgroundColor: const Color(0xFF16213e),
        actions: [
          IconButton(
            tooltip: loc.lanRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : folders == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(loc.lanLoadFailed),
                  const SizedBox(height: 12),
                  ElevatedButton(onPressed: _load, child: Text(loc.lanRetry)),
                ],
              ),
            )
          : folders.isEmpty
          ? Center(child: Text(loc.lanNoFolders))
          : _buildFolderList(loc, settings, folders),
    );
  }

  Widget _buildFolderList(
    AppLocalizations loc,
    SettingsProvider settings,
    List<RemoteFolder> folders,
  ) {
    final selectedIds = widget.selectMode
        ? settings.sharedFolders
              .where((ref) => ref.deviceId == widget.device.id)
              .map((ref) => ref.folderId)
              .toSet()
        : const <String>{};

    final list = ListView.separated(
      itemCount: folders.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final folder = folders[index];
        final added = selectedIds.contains(folder.id);
        return ListTile(
          leading: Icon(
            widget.selectMode ? Icons.folder_open : Icons.folder_shared,
            color: widget.selectMode && added
                ? const Color(0xFF00b894)
                : const Color(0xFF0984e3),
          ),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(loc.lanVideoCount(folder.videoCount)),
          trailing: widget.selectMode
              ? IconButton(
                  tooltip: added ? loc.lanRemove : loc.lanAddSource,
                  icon: Icon(
                    added ? Icons.check_circle : Icons.add_circle_outline,
                    color: added ? const Color(0xFF00b894) : Colors.grey,
                  ),
                  onPressed: () => _toggleSelection(folder, added),
                )
              : IconButton(
                  tooltip: loc.lanAddSource,
                  icon: Icon(
                    added ? Icons.check : Icons.add_to_queue,
                    color: added ? Colors.green : null,
                  ),
                  onPressed: added ? null : () => _addSource(folder),
                ),
          onTap: widget.selectMode
              ? () => _toggleSelection(folder, added)
              : () => _openFolder(folder),
        );
      },
    );

    if (!widget.selectMode) return list;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 18, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  loc.lanSelectSharedFoldersHint,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }
}
