import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Represents the result of a prepare() call.
class Live2dModelCacheProbe {
  const Live2dModelCacheProbe({
    /// Local URL to the model JSON, if immediately available (cache hit).
    /// Null if cache miss (download needed or in progress).
    this.localModelUrl,
    /// True if a download was started (cache miss, background download happening).
    required this.downloadStarted,
  });

  final String? localModelUrl;
  final bool downloadStarted;
}

/// Represents the state of an in-progress or completed download.
class _DownloadState {
  _DownloadState({
    required this.future,
    required this.completer,
    required this.status,
  });

  final Future<String?> future;
  final Completer<String?> completer;
  
  /// 'pending' = downloading, 'success' = completed with URL, 'failed' = completed with null
  String status; // pending | success | failed
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
  
  /// Tracks in-progress downloads: modelId -> _DownloadState
  final Map<String, _DownloadState> _downloadStates = <String, _DownloadState>{};

  /// Maximum retries per file before giving up on that file.
  static const int _maxFileRetries = 5;
  
  /// Initial delay between retries (exponential backoff).
  static const Duration _initialRetryDelay = Duration(milliseconds: 1000);
  
  /// Maximum retries for the manifest itself.
  static const int _maxManifestRetries = 3;

  /// Ensures the local HTTP server is running.
  Future<void> _ensureServer() async {
    if (_server != null) return;
    final root = await _getCacheRoot();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
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
    debugPrint('Live2dModelCache server started on port ${_server!.port}');
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

  /// Main entry point: prepares the model for loading.
  /// 
  /// Returns immediately with:
  /// - localModelUrl: if model is cached and ready
  /// - downloadStarted: true if background download is in progress
  /// 
  /// If download is already in progress when called, waits for it to complete
  /// and returns the result (either URL or null if failed).
  Future<Live2dModelCacheProbe> prepare({
    required String basePageUrl,
    required String appPassword,
    required String modelId,
  }) async {
    await _ensureServer();
    
    // Step 1: Check if we have a valid cached model
    final readyMeta = await _readReadyMeta(modelId);
    if (readyMeta != null && await _isReadyMetaUsable(readyMeta)) {
      final url = _buildLocalModelUrl(readyMeta.modelJsonPath);
      debugPrint('Live2dModelCache cache hit modelId=$modelId url=$url');
      return Live2dModelCacheProbe(
        localModelUrl: url,
        downloadStarted: false,
      );
    }

    // Step 2: Check if download is already in progress
    final existingState = _downloadStates[modelId];
    if (existingState != null && existingState.status == 'pending') {
      debugPrint('Live2dModelCache download already in progress for modelId=$modelId, waiting...');
      // Wait for the in-progress download to complete
      final result = await existingState.future;
      if (result != null) {
        return Live2dModelCacheProbe(
          localModelUrl: result,
          downloadStarted: true,
        );
      }
      // Download failed, fall through to start a new one
      debugPrint('Live2dModelCache previous download failed for modelId=$modelId, retrying...');
    }

    // Step 3: Start a new download
    debugPrint('Live2dModelCache starting download for modelId=$modelId');
    return _startDownload(
      basePageUrl: basePageUrl,
      appPassword: appPassword,
      modelId: modelId,
    );
  }

  /// Starts a new download and returns immediately with downloadStarted: true.
  Live2dModelCacheProbe _startDownload({
    required String basePageUrl,
    required String appPassword,
    required String modelId,
  }) {
    final completer = Completer<String?>();
    final state = _DownloadState(
      future: completer.future,
      completer: completer,
      status: 'pending',
    );
    _downloadStates[modelId] = state;
    
    // Start download in background
    _runDownload(
      basePageUrl: basePageUrl,
      appPassword: appPassword,
      modelId: modelId,
      state: state,
    ).then((url) {
      if (url != null) {
        state.status = 'success';
        completer.complete(url);
      } else {
        state.status = 'failed';
        completer.complete(null);
      }
    }).whenComplete(() {
      // Clean up after a delay to allow new downloads to reuse the slot
      Future.delayed(const Duration(seconds: 30), () {
        _downloadStates.remove(modelId);
      });
    });

    return Live2dModelCacheProbe(
      localModelUrl: null,
      downloadStarted: true,
    );
  }

  /// Runs the actual download, retrying individual files until success.
  Future<String?> _runDownload({
    required String basePageUrl,
    required String appPassword,
    required String modelId,
    required _DownloadState state,
  }) async {
    try {
      final baseUri = Uri.parse(basePageUrl);
      final manifestUri = baseUri.resolve('/api/model?model=${Uri.encodeQueryComponent(modelId)}');
      final headers = _buildAuthHeaders(appPassword);

      // Step 1: Download manifest with retry
      final manifestResponse = await _downloadWithRetry(
        manifestUri, 
        headers,
        retries: _maxManifestRetries,
        description: 'manifest',
      );
      if (manifestResponse == null) {
        stderr.writeln('Live2dModelCache manifest download failed after retries');
        return null;
      }
      if (manifestResponse.statusCode < 200 || manifestResponse.statusCode >= 300) {
        stderr.writeln('Live2dModelCache manifest download failed: ${manifestResponse.statusCode}');
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

      // Step 2: Download modelJson with retry
      final modelJsonResponse = await _downloadWithRetry(
        modelJsonUri,
        headers,
        description: 'modelJson',
      );
      if (modelJsonResponse == null) {
        stderr.writeln('Live2dModelCache modelJson download failed after retries');
        return null;
      }
      final modelJsonBytes = modelJsonResponse.bodyBytes;

      // Parse to find all referenced files
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

      // Step 3: Download each referenced file, retrying individually until success
      final publicRoot = await _publicRoot();
      final normalizedModelDir = p.posix.dirname(modelJsonPath);

      for (final ref in fileRefs) {
        final normalizedRef = _normalizeRelativePath(
          ref == modelJsonPath 
            ? ref 
            : p.posix.normalize(p.posix.join(normalizedModelDir, ref)),
        );
        final finalFile = File(p.join(publicRoot.path, normalizedRef));

        // Delete existing file first to ensure clean download (handles incomplete/corrupted files)
        if (await finalFile.exists()) {
          await finalFile.delete();
        }

        // Try to download this file, retrying until success
        final bytes = await _downloadFileWithInfiniteRetry(
          ref == modelJsonPath ? modelJsonUri : modelJsonUri.resolve(ref),
          ref == modelJsonPath ? modelJsonBytes : null,
          headers,
          finalFile,
          description: ref,
        );
        
        if (bytes == null) {
          // This file failed even after all retries - give up
          stderr.writeln('Live2dModelCache file failed after all retries: $ref');
          return null;
        }
      }

      // Step 4: Verify all files exist
      for (final ref in fileRefs) {
        final normalizedRef = _normalizeRelativePath(
          ref == modelJsonPath 
            ? ref 
            : p.posix.normalize(p.posix.join(normalizedModelDir, ref)),
        );
        final finalFile = File(p.join(publicRoot.path, normalizedRef));
        if (!await finalFile.exists()) {
          stderr.writeln('Live2dModelCache file missing after download: $normalizedRef');
          return null;
        }
      }

      // Step 5: Write meta file to mark download complete
      final meta = _Live2dModelReadyMeta(
        modelId: modelId,
        modelJsonPath: modelJsonPath,
        sourceBaseUrl: basePageUrl,
        cachedAt: DateTime.now().toUtc(),
      );
      final metaFile = await _metaFile(modelId);
      await metaFile.writeAsString(jsonEncode(meta.toJson()), flush: true);
      
      final resultUrl = _buildLocalModelUrl(modelJsonPath);
      debugPrint('Live2dModelCache download complete for modelId=$modelId url=$resultUrl');
      return resultUrl;
    } catch (error, stackTrace) {
      stderr.writeln('Live2dModelCache download error: $error\n$stackTrace');
      return null;
    }
  }

  /// Downloads a file, retrying indefinitely until success.
  /// Returns null only if cancelled.
  Future<List<int>?> _downloadFileWithInfiniteRetry(
    Uri uri,
    List<int>? cachedBytes,
    Map<String, String> headers,
    File targetFile, {
    String description = 'file',
  }) async {
    int attempt = 0;
    while (true) {
      attempt++;
      try {
        // If we have cached bytes and this is the modelJson, use them directly
        final bytes = cachedBytes ?? await _downloadBytesWithRetry(uri, headers);
        if (bytes != null) {
          // Write the file
          await targetFile.parent.create(recursive: true);
          await targetFile.writeAsBytes(bytes, flush: true);
          debugPrint('Live2dModelCache $description downloaded successfully on attempt $attempt');
          return bytes;
        }
        stderr.writeln('Live2dModelCache $description attempt $attempt failed (null)');
      } catch (e) {
        stderr.writeln('Live2dModelCache $description attempt $attempt error: $e');
      }
      
      // Exponential backoff, max 30 seconds
      final delayMs = (_initialRetryDelay.inMilliseconds * attempt).clamp(500, 30000);
      debugPrint('Live2dModelCache $description retrying in ${delayMs ~/ 1000}s (attempt $attempt)...');
      await Future.delayed(Duration(milliseconds: delayMs));
    }
  }

  /// Downloads bytes with retry, returns null after all retries exhausted.
  Future<List<int>?> _downloadBytesWithRetry(
    Uri uri,
    Map<String, String> headers, {
    int retries = _maxFileRetries,
  }) async {
    for (int attempt = 1; attempt <= retries; attempt++) {
      try {
        final response = await http.get(uri, headers: headers);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response.bodyBytes;
        }
        stderr.writeln('Live2dModelCache bytes attempt $attempt/$retries failed: ${response.statusCode}');
      } catch (e) {
        stderr.writeln('Live2dModelCache bytes attempt $attempt/$retries error: $e');
      }
      if (attempt < retries) {
        final delay = Duration(milliseconds: _initialRetryDelay.inMilliseconds * attempt);
        await Future.delayed(delay);
      }
    }
    return null;
  }

  Future<http.Response?> _downloadWithRetry(
    Uri uri,
    Map<String, String> headers, {
    int retries = _maxManifestRetries,
    String description = 'download',
  }) async {
    for (int attempt = 1; attempt <= retries; attempt++) {
      try {
        final response = await http.get(uri, headers: headers);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        stderr.writeln('Live2dModelCache $description attempt $attempt/$retries failed: ${response.statusCode}');
      } catch (e) {
        stderr.writeln('Live2dModelCache $description attempt $attempt/$retries error: $e');
      }
      if (attempt < retries) {
        final delay = Duration(milliseconds: _initialRetryDelay.inMilliseconds * attempt);
        await Future.delayed(delay);
      }
    }
    return null;
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
  
  void debugPrint(String message) {
    // ignore: avoid_print
    print('[Live2dModelCache] $message');
  }
}
