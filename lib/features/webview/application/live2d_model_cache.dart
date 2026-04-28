import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class Live2dModelCacheProbe {
  const Live2dModelCacheProbe({
    required this.localModelUrl,
    required this.downloadStarted,
  });

  final String? localModelUrl;
  final bool downloadStarted;
}

class _Live2dModelReadyMeta {
  const _Live2dModelReadyMeta({
    required this.modelId,
    required this.modelJsonPath,
    required this.sourceBaseUrl,
    required this.cachedAt,
  });

  final String modelId;
  final String modelJsonPath;
  final String sourceBaseUrl;
  final DateTime cachedAt;

  Map<String, dynamic> toJson() => {
    'modelId': modelId,
    'modelJsonPath': modelJsonPath,
    'sourceBaseUrl': sourceBaseUrl,
    'cachedAt': cachedAt.toIso8601String(),
  };

  static _Live2dModelReadyMeta? fromJson(Map<String, dynamic> json) {
    final modelId = (json['modelId'] as String? ?? '').trim();
    final modelJsonPath = (json['modelJsonPath'] as String? ?? '').trim();
    final sourceBaseUrl = (json['sourceBaseUrl'] as String? ?? '').trim();
    final cachedAtRaw = (json['cachedAt'] as String? ?? '').trim();
    if (modelId.isEmpty || modelJsonPath.isEmpty || sourceBaseUrl.isEmpty) {
      return null;
    }
    final cachedAt = DateTime.tryParse(cachedAtRaw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return _Live2dModelReadyMeta(
      modelId: modelId,
      modelJsonPath: modelJsonPath,
      sourceBaseUrl: sourceBaseUrl,
      cachedAt: cachedAt,
    );
  }
}

class Live2dModelCache {
  Live2dModelCache._();

  static final Live2dModelCache instance = Live2dModelCache._();

  HttpServer? _server;
  Directory? _cacheRoot;
  final Map<String, Future<String?>> _downloadFutures = <String, Future<String?>>{};

  Future<Live2dModelCacheProbe> prepare({
    required String basePageUrl,
    required String appPassword,
    required String modelId,
  }) async {
    await _ensureServer();
    final readyMeta = await _readReadyMeta(modelId);
    if (readyMeta != null && await _isReadyMetaUsable(readyMeta)) {
      return Live2dModelCacheProbe(
        localModelUrl: _buildLocalModelUrl(readyMeta.modelJsonPath),
        downloadStarted: false,
      );
    }

    _downloadFutures[modelId] ??= _downloadModel(
      basePageUrl: basePageUrl,
      appPassword: appPassword,
      modelId: modelId,
    ).whenComplete(() {
      _downloadFutures.remove(modelId);
    });

    return const Live2dModelCacheProbe(
      localModelUrl: null,
      downloadStarted: true,
    );
  }

  Future<String?> waitForLocalModelUrl(String modelId) async {
    final readyMeta = await _readReadyMeta(modelId);
    if (readyMeta != null && await _isReadyMetaUsable(readyMeta)) {
      return _buildLocalModelUrl(readyMeta.modelJsonPath);
    }
    final future = _downloadFutures[modelId];
    if (future == null) return null;
    return future;
  }

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final root = await _getCacheRoot();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await _handleRequest(root, request);
      } catch (error, stackTrace) {
        stderr.writeln('Live2dModelCache server error: $error\n$stackTrace');
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('server error');
        await request.response.close();
      }
    });
    _server = server;
  }

  Future<Directory> _getCacheRoot() async {
    if (_cacheRoot != null) return _cacheRoot!;
    final dir = await getApplicationSupportDirectory();
    final root = Directory(p.join(dir.path, 'live2d_model_cache'));
    await root.create(recursive: true);
    _cacheRoot = root;
    return root;
  }

  Future<File> _metaFile(String modelId) async {
    final root = await _getCacheRoot();
    final metaDir = Directory(p.join(root.path, 'meta'));
    await metaDir.create(recursive: true);
    return File(p.join(metaDir.path, '$modelId.json'));
  }

  Future<Directory> _publicRoot() async {
    final root = await _getCacheRoot();
    final publicDir = Directory(p.join(root.path, 'public'));
    await publicDir.create(recursive: true);
    return publicDir;
  }

  Future<_Live2dModelReadyMeta?> _readReadyMeta(String modelId) async {
    final file = await _metaFile(modelId);
    if (!await file.exists()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      return _Live2dModelReadyMeta.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isReadyMetaUsable(_Live2dModelReadyMeta meta) async {
    final publicRoot = await _publicRoot();
    final normalized = _normalizeRelativePath(meta.modelJsonPath);
    final modelFile = File(p.join(publicRoot.path, normalized));
    return modelFile.exists();
  }

  String _buildLocalModelUrl(String modelJsonPath) {
    final server = _server;
    if (server == null) {
      throw StateError('local cache server not started');
    }
    final normalized = _normalizeRelativePath(modelJsonPath)
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return 'http://127.0.0.1:${server.port}/$normalized';
  }

  Future<String?> _downloadModel({
    required String basePageUrl,
    required String appPassword,
    required String modelId,
  }) async {
    try {
      final baseUri = Uri.parse(basePageUrl);
      final manifestUri = baseUri.resolve('/api/model?model=${Uri.encodeQueryComponent(modelId)}');
      final headers = _buildAuthHeaders(appPassword);
      final manifestResponse = await http.get(manifestUri, headers: headers);
      if (manifestResponse.statusCode < 200 || manifestResponse.statusCode >= 300) {
        stderr.writeln('Live2dModelCache manifest download failed: ${manifestResponse.statusCode} ${manifestResponse.body}');
        return null;
      }
      final manifestJson = jsonDecode(utf8.decode(manifestResponse.bodyBytes));
      if (manifestJson is! Map<String, dynamic>) {
        stderr.writeln('Live2dModelCache manifest is not a JSON object');
        return null;
      }
      final model = manifestJson['model'];
      if (model is! Map<String, dynamic>) {
        stderr.writeln('Live2dModelCache manifest missing model field');
        return null;
      }
      final modelJsonPathRaw = (model['modelJson'] as String? ?? '').trim();
      if (modelJsonPathRaw.isEmpty) {
        stderr.writeln('Live2dModelCache manifest missing modelJson');
        return null;
      }

      final modelJsonPath = _normalizeRelativePath(modelJsonPathRaw);
      final modelJsonUri = baseUri.resolve(modelJsonPathRaw);
      final modelJsonResponse = await http.get(modelJsonUri, headers: headers);
      if (modelJsonResponse.statusCode < 200 || modelJsonResponse.statusCode >= 300) {
        stderr.writeln('Live2dModelCache modelJson download failed: ${modelJsonResponse.statusCode} ${modelJsonResponse.body}');
        return null;
      }
      final modelJsonBytes = modelJsonResponse.bodyBytes;
      final modelJson = jsonDecode(utf8.decode(modelJsonBytes));
      if (modelJson is! Map<String, dynamic>) {
        stderr.writeln('Live2dModelCache modelJson is not a JSON object');
        return null;
      }

      final fileRefs = <String>{modelJsonPath};
      final fileReferences = modelJson['FileReferences'];
      if (fileReferences is Map<String, dynamic>) {
        for (final value in fileReferences.values) {
          _collectRelativeRefs(value, fileRefs);
        }
      }

      final publicRoot = await _publicRoot();
      final tempRoot = Directory(p.join(publicRoot.path, '.tmp_$modelId'));
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
      await tempRoot.create(recursive: true);

      final normalizedModelDir = p.posix.dirname(modelJsonPath);
      for (final ref in fileRefs) {
        final normalizedRef = _normalizeRelativePath(
          ref == modelJsonPath ? ref : p.posix.normalize(p.posix.join(normalizedModelDir, ref)),
        );
        final remoteUri = ref == modelJsonPath
            ? modelJsonUri
            : modelJsonUri.resolve(ref);
        final bytes = ref == modelJsonPath
            ? modelJsonBytes
            : await _downloadBytes(remoteUri, headers);
        if (bytes == null) {
          stderr.writeln('Live2dModelCache file download failed: $remoteUri');
          return null;
        }
        final targetFile = File(p.join(tempRoot.path, normalizedRef));
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(bytes, flush: true);
      }

      final finalRootDir = Directory(p.join(publicRoot.path, 'models', modelId));
      if (await finalRootDir.exists()) {
        await finalRootDir.delete(recursive: true);
      }
      final sourceModelDir = Directory(p.join(tempRoot.path, 'models', modelId));
      if (!await sourceModelDir.exists()) {
        stderr.writeln('Live2dModelCache temp model dir missing: ${sourceModelDir.path}');
        return null;
      }
      await sourceModelDir.rename(finalRootDir.path);
      await tempRoot.delete(recursive: true);

      final meta = _Live2dModelReadyMeta(
        modelId: modelId,
        modelJsonPath: modelJsonPath,
        sourceBaseUrl: basePageUrl,
        cachedAt: DateTime.now().toUtc(),
      );
      final metaFile = await _metaFile(modelId);
      await metaFile.writeAsString(jsonEncode(meta.toJson()), flush: true);
      return _buildLocalModelUrl(modelJsonPath);
    } catch (error, stackTrace) {
      stderr.writeln('Live2dModelCache download error: $error\n$stackTrace');
      return null;
    }
  }

  Future<List<int>?> _downloadBytes(Uri uri, Map<String, String> headers) async {
    final response = await http.get(uri, headers: headers);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    return response.bodyBytes;
  }

  void _collectRelativeRefs(dynamic value, Set<String> refs) {
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        refs.add(trimmed);
      }
      return;
    }
    if (value is List) {
      for (final item in value) {
        _collectRelativeRefs(item, refs);
      }
      return;
    }
    if (value is Map) {
      for (final entryValue in value.values) {
        _collectRelativeRefs(entryValue, refs);
      }
    }
  }

  Future<void> _handleRequest(Directory cacheRoot, HttpRequest request) async {
    request.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', '*')
      ..set('Cache-Control', 'public, max-age=31536000, immutable');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    final relativePath = _normalizeRelativePath(Uri.decodeComponent(request.uri.path));
    final file = File(p.join(cacheRoot.path, 'public', relativePath));
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = _contentTypeForPath(file.path);
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  ContentType _contentTypeForPath(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.json':
        return ContentType('application', 'json', charset: 'utf-8');
      case '.png':
        return ContentType('image', 'png');
      case '.jpg':
      case '.jpeg':
        return ContentType('image', 'jpeg');
      case '.webp':
        return ContentType('image', 'webp');
      case '.gif':
        return ContentType('image', 'gif');
      case '.moc3':
      case '.cdi3.json':
      case '.physics3.json':
      case '.motion3.json':
      case '.exp3.json':
        return ContentType.binary;
      default:
        return ContentType.binary;
    }
  }

  Map<String, String> _buildAuthHeaders(String appPassword) {
    final password = appPassword.trim();
    if (password.isEmpty) return const <String, String>{};
    return <String, String>{
      'X-AliceChat-Password': password,
      'Authorization': 'Bearer $password',
    };
  }

  String _normalizeRelativePath(String pathValue) {
    final trimmed = pathValue.trim();
    if (trimmed.isEmpty) return '';
    return p.posix.normalize(trimmed.replaceFirst(RegExp(r'^/+'), ''));
  }
}
