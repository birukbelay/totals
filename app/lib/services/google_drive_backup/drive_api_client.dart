import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Returns an OAuth access token for the Drive API. [forceRefresh] asks for
/// a new token after the previous one was rejected.
typedef DriveAccessTokenProvider = Future<String?> Function({
  bool forceRefresh,
});

class DriveApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? reason;

  const DriveApiException(this.message, {this.statusCode, this.reason});

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// A file in the app's hidden Drive folder.
class DriveFile {
  final String id;
  final String name;
  final int size;
  final DateTime? createdTime;
  final Map<String, String> appProperties;

  const DriveFile({
    required this.id,
    required this.name,
    this.size = 0,
    this.createdTime,
    this.appProperties = const {},
  });

  factory DriveFile.fromJson(Map<String, dynamic> json) {
    final properties = json['appProperties'];
    return DriveFile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      size: int.tryParse('${json['size'] ?? ''}') ?? 0,
      createdTime: DateTime.tryParse(json['createdTime'] as String? ?? ''),
      appProperties: properties is Map
          ? properties.map(
              (key, value) => MapEntry('$key', '$value'),
            )
          : const {},
    );
  }
}

/// The signed-in Drive user, as reported by `about.get`.
class DriveUser {
  final String? email;
  final String? displayName;

  const DriveUser({this.email, this.displayName});
}

/// Minimal Drive v3 REST client limited to the `appDataFolder` space, the
/// only place the `drive.appdata` scope can read or write.
class DriveApiClient {
  DriveApiClient({
    required DriveAccessTokenProvider tokenProvider,
    http.Client? client,
    Random? random,
  })  : _tokenProvider = tokenProvider,
        _client = client ?? http.Client(),
        _ownsClient = client == null,
        _random = random ?? Random.secure();

  static const String appDataFolder = 'appDataFolder';
  static const int maxDownloadBytes = 100 * 1024 * 1024;
  static const String _fileFields = 'id,name,size,createdTime,appProperties';
  static const Duration _timeout = Duration(seconds: 60);

  final DriveAccessTokenProvider _tokenProvider;
  final http.Client _client;
  final bool _ownsClient;
  final Random _random;

  Future<DriveUser> getUser() async {
    final response = await _send(
      () => http.Request(
        'GET',
        Uri.https('www.googleapis.com', '/drive/v3/about', {
          'fields': 'user(emailAddress,displayName)',
        }),
      ),
    );
    final user = _decodeMap(response.body)['user'];
    if (user is! Map) return const DriveUser();
    return DriveUser(
      email: user['emailAddress'] as String?,
      displayName: user['displayName'] as String?,
    );
  }

  /// Lists the app folder's files, newest first.
  Future<List<DriveFile>> listFiles() async {
    final files = <DriveFile>[];
    String? pageToken;
    do {
      final query = <String, String>{
        'spaces': appDataFolder,
        'fields': 'nextPageToken,files($_fileFields)',
        'orderBy': 'createdTime desc',
        'pageSize': '100',
        if (pageToken != null) 'pageToken': pageToken,
      };
      final response = await _send(
        () => http.Request(
          'GET',
          Uri.https('www.googleapis.com', '/drive/v3/files', query),
        ),
      );
      final body = _decodeMap(response.body);
      for (final file in body['files'] as List? ?? const []) {
        if (file is Map) {
          files.add(DriveFile.fromJson(Map<String, dynamic>.from(file)));
        }
      }
      final next = body['nextPageToken'] as String?;
      pageToken = next == null || next.isEmpty ? null : next;
    } while (pageToken != null);
    return files;
  }

  /// Uploads [bytes] as a new file in the app folder.
  Future<DriveFile> uploadFile({
    required String name,
    required List<int> bytes,
    String mimeType = 'application/octet-stream',
    Map<String, String> appProperties = const {},
  }) async {
    final metadata = <String, dynamic>{
      'name': name,
      'parents': const [appDataFolder],
      'mimeType': mimeType,
      if (appProperties.isNotEmpty) 'appProperties': appProperties,
    };
    final boundary = 'totals_${_randomBoundary()}';
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(metadata)}\r\n'
          '--$boundary\r\n'
          'Content-Type: $mimeType\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final payload = body.takeBytes();

    final response = await _send(() {
      return http.Request(
        'POST',
        Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
          'uploadType': 'multipart',
          'fields': _fileFields,
        }),
      )
        ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
        ..bodyBytes = payload;
    });
    final file = DriveFile.fromJson(_decodeMap(response.body));
    if (file.id.isEmpty) {
      throw const DriveApiException(
        'Google Drive did not confirm the uploaded backup.',
      );
    }
    return file;
  }

  Future<List<int>> downloadFile(
    String fileId, {
    int maximumBytes = maxDownloadBytes,
  }) async {
    final response = await _send(
      () => http.Request(
        'GET',
        Uri.https(
          'www.googleapis.com',
          '/drive/v3/files/${Uri.encodeComponent(fileId)}',
          {'alt': 'media'},
        ),
      ),
    );
    if (response.bodyBytes.length > maximumBytes) {
      throw const DriveApiException(
        'This backup is too large to restore in the app.',
      );
    }
    return response.bodyBytes;
  }

  /// Deletes [fileId]. A file that is already gone counts as deleted.
  Future<void> deleteFile(String fileId) async {
    try {
      await _send(
        () => http.Request(
          'DELETE',
          Uri.https(
            'www.googleapis.com',
            '/drive/v3/files/${Uri.encodeComponent(fileId)}',
          ),
        ),
      );
    } on DriveApiException catch (error) {
      if (error.statusCode != 404) rethrow;
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Sends the request built by [build], retrying once with a fresh token
  /// when Google rejects the current one.
  Future<http.Response> _send(http.Request Function() build) async {
    var token = await _token(forceRefresh: false);
    for (var attempt = 0;; attempt++) {
      final request = build()..headers['Authorization'] = 'Bearer $token';
      final http.Response response;
      try {
        response = await http.Response.fromStream(
          await _client.send(request).timeout(_timeout),
        ).timeout(_timeout);
      } on TimeoutException {
        throw const DriveApiException(
          'Google Drive took too long to respond. Try again.',
        );
      } on SocketException {
        throw const DriveApiException(
          'Could not reach Google Drive. Check your connection.',
        );
      } on http.ClientException {
        throw const DriveApiException(
          'Could not reach Google Drive. Check your connection.',
        );
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }
      if (response.statusCode == 401 && attempt == 0) {
        token = await _token(forceRefresh: true);
        continue;
      }
      throw _errorFor(response);
    }
  }

  Future<String> _token({required bool forceRefresh}) async {
    final token = (await _tokenProvider(forceRefresh: forceRefresh))?.trim();
    if (token == null || token.isEmpty) {
      throw const DriveApiException(
        'Sign in to Google again to use Drive backup.',
        statusCode: 401,
      );
    }
    return token;
  }

  static DriveApiException _errorFor(http.Response response) {
    String? reason;
    String? detail;
    try {
      final error = _decodeMap(response.body)['error'];
      if (error is Map) {
        detail = error['message'] as String?;
        final errors = error['errors'];
        if (errors is List && errors.isNotEmpty && errors.first is Map) {
          reason = (errors.first as Map)['reason'] as String?;
        }
      }
    } catch (_) {}

    final status = response.statusCode;
    final String message;
    if (status == 401) {
      message = 'Google access expired. Sign in to Google again.';
    } else if (reason == 'storageQuotaExceeded') {
      message = 'Your Google Drive is full. Free up space and try again.';
    } else if (reason == 'accessNotConfigured' ||
        reason == 'SERVICE_DISABLED') {
      message = 'The Google Drive API is not enabled for this app.';
    } else if (status == 403 &&
        (reason == 'rateLimitExceeded' || reason == 'userRateLimitExceeded')) {
      message = 'Google Drive is busy. Try again in a minute.';
    } else if (status == 403) {
      message = 'Google Drive refused access. Sign in to Google again.';
    } else if (status == 404) {
      message = 'This backup is no longer in Google Drive.';
    } else if (status >= 500) {
      message = 'Google Drive is unavailable right now. Try again later.';
    } else {
      message = detail?.trim().isNotEmpty == true
          ? detail!.trim()
          : 'Google Drive request failed (HTTP $status).';
    }
    return DriveApiException(message, statusCode: status, reason: reason);
  }

  static Map<String, dynamic> _decodeMap(String body) {
    if (body.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      throw const DriveApiException(
        'Google Drive returned an unexpected response.',
      );
    }
  }

  String _randomBoundary() {
    return List<int>.generate(12, (_) => _random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
