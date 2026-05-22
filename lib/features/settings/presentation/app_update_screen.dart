import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});

  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  static const _manifestUrl =
      'https://yzcos-1317705976.cos.ap-singapore.myqcloud.com/apk/latest.json';

  PackageInfo? _current;
  AppUpdateManifest? _latest;
  bool _checking = false;
  bool _downloading = false;
  double? _progress;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCurrentVersion();
  }

  Future<void> _loadCurrentVersion() async {
    final current = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _current = current);
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _error = null;
      _status = '正在检查更新…';
      _progress = null;
    });
    try {
      final response = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('更新清单读取失败：HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw Exception('更新清单格式不正确');
      }
      final latest = AppUpdateManifest.fromJson(decoded);
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _status = _hasUpdate(latest) ? '发现新版本' : '已经是最新版本';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  bool _hasUpdate(AppUpdateManifest latest) {
    final currentBuild = int.tryParse(_current?.buildNumber ?? '') ?? 0;
    return latest.buildNumber > currentBuild;
  }

  Future<void> _downloadAndInstall() async {
    final latest = _latest;
    if (latest == null) return;
    if (!Platform.isAndroid) {
      setState(() => _error = '当前平台不支持 APK 安装');
      return;
    }

    setState(() {
      _downloading = true;
      _error = null;
      _status = '正在下载安装包…';
      _progress = 0;
    });

    try {
      final cacheDir = await getTemporaryDirectory();
      final updateDir = Directory(p.join(cacheDir.path, 'alicechat_update'));
      if (await updateDir.exists()) {
        await updateDir.delete(recursive: true);
      }
      await updateDir.create(recursive: true);

      final zipPath = p.join(
        updateDir.path,
        'alicechat-${latest.buildTime}.apk.zip',
      );
      final zipFile = File(zipPath);
      await _downloadFile(latest.apkZipUrl, zipFile, expectedSize: latest.size);

      setState(() {
        _status = '正在校验安装包…';
        _progress = null;
      });
      await _verifySha256(zipFile, latest.sha256);

      setState(() => _status = '正在解压安装包…');
      final apkFile = await _extractApk(zipFile, updateDir);

      setState(() => _status = '正在打开系统安装器…');
      final result = await OpenFilex.open(
        apkFile.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw Exception(result.message);
      }
      if (!mounted) return;
      setState(() {
        _status = '已交给系统安装器，请按提示完成安装';
        _progress = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _status = null;
      });
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _downloadFile(
    String url,
    File target, {
    required int? expectedSize,
  }) async {
    final request = http.Request('GET', Uri.parse(url));
    final client = http.Client();
    final response = await client.send(request);

    try {
      if (response.statusCode != 200) {
        throw Exception('安装包下载失败：HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? expectedSize ?? 0;
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response.stream) {
          received += chunk.length;
          sink.add(chunk);
          if (mounted && total > 0) {
            setState(() => _progress = received / total);
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  Future<void> _verifySha256(File file, String expected) async {
    final normalized = expected.trim().toLowerCase();
    if (normalized.isEmpty) return;
    final actual = sha256.convert(await file.readAsBytes()).toString();
    if (actual != normalized) {
      throw Exception('安装包校验失败，请重新下载');
    }
  }

  Future<File> _extractApk(File zipFile, Directory targetDir) async {
    final input = InputFileStream(zipFile.path);
    final archive = ZipDecoder().decodeStream(input);
    for (final item in archive.files) {
      if (!item.isFile || !item.name.endsWith('.apk')) continue;
      final apkPath = p.join(targetDir.path, p.basename(item.name));
      final output = OutputFileStream(apkPath);
      item.writeContent(output);
      await output.close();
      return File(apkPath);
    }
    throw Exception('压缩包里没有找到 APK');
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latest;
    final hasUpdate = latest != null && _hasUpdate(latest);
    final current = _current;

    return Scaffold(
      appBar: AppBar(title: const Text('应用更新')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _UpdateCard(
            icon: Icons.system_update_rounded,
            title: 'AliceChat 更新',
            subtitle: '从 GitHub Actions 上传到腾讯 COS 的安装包检查新版本。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoRow(
                  label: '当前版本',
                  value:
                      current == null
                          ? '读取中…'
                          : '${current.version}+${current.buildNumber}',
                ),
                const SizedBox(height: 10),
                _InfoRow(
                  label: '最新版本',
                  value:
                      latest == null
                          ? '尚未检查'
                          : '${latest.versionName}+${latest.buildNumber}',
                ),
                if ((latest?.buildTime ?? '').isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _InfoRow(label: '构建时间', value: _formatBuildTime(latest!)),
                ],
                if ((latest?.releaseNotes ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    latest!.releaseNotes.trim(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF475467),
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_status != null)
            _StatusBanner(
              icon: hasUpdate ? Icons.new_releases_rounded : Icons.check_circle,
              text: _status!,
              color:
                  hasUpdate ? const Color(0xFF2563EB) : const Color(0xFF059669),
            ),
          if (_error != null)
            _StatusBanner(
              icon: Icons.error_outline_rounded,
              text: _error!,
              color: const Color(0xFFDC2626),
            ),
          if (_progress != null) ...[
            const SizedBox(height: 14),
            LinearProgressIndicator(value: _progress!.clamp(0, 1)),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _checking || _downloading ? null : _checkUpdate,
            icon:
                _checking
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.refresh_rounded),
            label: Text(_checking ? '检查中…' : '检查更新'),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed:
                hasUpdate && !_checking && !_downloading
                    ? _downloadAndInstall
                    : null,
            icon:
                _downloading
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.download_rounded),
            label: Text(_downloading ? '处理中…' : '下载并安装'),
          ),
          const SizedBox(height: 12),
          Text(
            '安装时会跳转到 Android 系统安装器；如果系统拦截，需要允许 AliceChat 安装未知来源应用。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF667085),
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  String _formatBuildTime(AppUpdateManifest manifest) {
    final value = manifest.buildTime;
    if (value.length != 12) return value;
    return '${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)} '
        '${value.substring(8, 10)}:${value.substring(10, 12)}';
  }
}

class AppUpdateManifest {
  const AppUpdateManifest({
    required this.versionName,
    required this.buildNumber,
    required this.buildTime,
    required this.apkZipUrl,
    required this.sha256,
    required this.size,
    required this.releaseNotes,
  });

  final String versionName;
  final int buildNumber;
  final String buildTime;
  final String apkZipUrl;
  final String sha256;
  final int? size;
  final String releaseNotes;

  factory AppUpdateManifest.fromJson(Map<String, dynamic> json) {
    return AppUpdateManifest(
      versionName: '${json['versionName'] ?? ''}',
      buildNumber: int.tryParse('${json['buildNumber'] ?? ''}') ?? 0,
      buildTime: '${json['buildTime'] ?? ''}',
      apkZipUrl: '${json['apkZipUrl'] ?? ''}',
      sha256: '${json['sha256'] ?? ''}',
      size: int.tryParse('${json['size'] ?? ''}'),
      releaseNotes: '${json['releaseNotes'] ?? ''}',
    );
  }
}

class _UpdateCard extends StatelessWidget {
  const _UpdateCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE8ECF4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: const Color(0xFF2563EB)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF667085),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: const Color(0xFF667085)),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
