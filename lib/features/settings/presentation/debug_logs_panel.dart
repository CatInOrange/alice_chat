import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/debug/debug_log_store.dart';
import '../../../core/debug/debug_log_uploader.dart';
import '../../../core/debug/native_debug_bridge.dart';

class DebugLogsPanel extends StatefulWidget {
  const DebugLogsPanel({super.key});

  @override
  State<DebugLogsPanel> createState() => _DebugLogsPanelState();
}

class _DebugLogsPanelState extends State<DebugLogsPanel> {
  bool _loadingNative = false;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    DebugLogStore.instance.ensureLoaded();
  }

  Future<void> _refreshNativeLogs() async {
    setState(() => _loadingNative = true);
    try {
      final lines = await NativeDebugBridge.instance.fetchNativeLogs();
      await DebugLogStore.instance.importLines(lines, fallbackTag: 'native');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已同步 ${lines.length} 条原生日志')),
      );
    } finally {
      if (mounted) setState(() => _loadingNative = false);
    }
  }

  Future<void> _copyLogs() async {
    final text = DebugLogStore.instance.exportText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制')),
    );
  }

  Future<void> _clearLogs() async {
    await DebugLogStore.instance.clear();
    await NativeDebugBridge.instance.clearNativeLogs();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已清空')),
    );
  }

  Future<void> _uploadLogs() async {
    setState(() => _uploading = true);
    try {
      final result = await DebugLogUploader.instance.upload();
      if (!mounted) return;
      final uploadId = (result['uploadId'] ?? '').toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(uploadId.isEmpty ? '日志已上传' : '日志已上传: $uploadId')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败: $error')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DebugLogStore.instance,
      builder: (context, _) {
        final entries = DebugLogStore.instance.entries;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '调试日志',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: '同步原生日志',
                      onPressed: _loadingNative ? null : _refreshNativeLogs,
                      icon: _loadingNative
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                    ),
                    IconButton(
                      tooltip: '复制日志',
                      onPressed: _copyLogs,
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                    IconButton(
                      tooltip: '上传日志',
                      onPressed: _uploading ? null : _uploadLogs,
                      icon: _uploading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_upload_outlined),
                    ),
                    IconButton(
                      tooltip: '清空日志',
                      onPressed: _clearLogs,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  height: 260,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: entries.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无日志',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView.builder(
                          reverse: false,
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: SelectableText(
                                entry.formatLine(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
