import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:totals/services/google_drive_backup/drive_api_client.dart';

void main() {
  DriveApiClient clientFor(
    MockClientHandler handler, {
    List<bool>? refreshes,
  }) {
    var tokenNumber = 0;
    return DriveApiClient(
      client: MockClient(handler),
      tokenProvider: ({bool forceRefresh = false}) async {
        refreshes?.add(forceRefresh);
        tokenNumber++;
        return 'token-$tokenNumber';
      },
    );
  }

  test('lists every page of the app folder', () async {
    final requests = <Uri>[];
    final client = clientFor((request) async {
      requests.add(request.url);
      expect(request.headers['Authorization'], startsWith('Bearer token-'));
      final page = request.url.queryParameters['pageToken'];
      if (page == null) {
        return http.Response(
          jsonEncode({
            'nextPageToken': 'p2',
            'files': [
              {
                'id': 'a',
                'name': 'one.totals',
                'size': '42',
                'createdTime': '2026-07-01T10:00:00.000Z',
                'appProperties': {'format': 'totals.backup'},
              },
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'files': [
            {'id': 'b', 'name': 'two.totals'},
          ],
        }),
        200,
      );
    });

    final files = await client.listFiles();

    expect(files.map((file) => file.id), ['a', 'b']);
    expect(files.first.size, 42);
    expect(files.first.createdTime, DateTime.utc(2026, 7, 1, 10));
    expect(files.first.appProperties['format'], 'totals.backup');
    expect(requests, hasLength(2));
    expect(requests.first.host, 'www.googleapis.com');
    expect(requests.first.path, '/drive/v3/files');
    expect(requests.first.queryParameters['spaces'], 'appDataFolder');
    expect(requests.last.queryParameters['pageToken'], 'p2');
  });

  test('uploads metadata and bytes as one multipart request', () async {
    late http.Request captured;
    final client = clientFor((request) async {
      captured = request;
      return http.Response(
        jsonEncode({'id': 'new-id', 'name': 'backup.totals', 'size': '3'}),
        200,
      );
    });

    final file = await client.uploadFile(
      name: 'backup.totals',
      bytes: const [1, 2, 3],
      appProperties: const {'format': 'totals.backup'},
    );

    expect(file.id, 'new-id');
    expect(captured.method, 'POST');
    expect(captured.url.path, '/upload/drive/v3/files');
    expect(captured.url.queryParameters['uploadType'], 'multipart');
    final contentType = captured.headers['Content-Type']!;
    expect(contentType, startsWith('multipart/related; boundary='));
    final boundary = contentType.split('boundary=').last;

    final body = latin1.decode(captured.bodyBytes);
    final parts = body.split('--$boundary');
    expect(parts.last.trim(), '--');
    final metadataPart = parts[1].split('\r\n\r\n');
    final metadata = jsonDecode(metadataPart[1].trim()) as Map;
    expect(metadata['name'], 'backup.totals');
    expect(metadata['parents'], ['appDataFolder']);
    expect(metadata['appProperties'], {'format': 'totals.backup'});
    final mediaPart = parts[2].split('\r\n\r\n');
    expect(mediaPart.first, contains('application/octet-stream'));
    expect(latin1.encode(mediaPart[1]), [1, 2, 3, 13, 10]);
  });

  test('retries once with a fresh token after a 401', () async {
    final refreshes = <bool>[];
    final tokens = <String?>[];
    final client = clientFor(
      (request) async {
        tokens.add(request.headers['Authorization']);
        if (tokens.length == 1) return http.Response('', 401);
        return http.Response.bytes(const [7, 8], 200);
      },
      refreshes: refreshes,
    );

    final bytes = await client.downloadFile('file-1');

    expect(bytes, [7, 8]);
    expect(refreshes, [false, true]);
    expect(tokens, ['Bearer token-1', 'Bearer token-2']);
  });

  test('a second 401 surfaces as unauthorized', () async {
    final client = clientFor((_) async => http.Response('', 401));

    await expectLater(
      client.getUser(),
      throwsA(
        isA<DriveApiException>().having(
          (error) => error.isUnauthorized,
          'isUnauthorized',
          isTrue,
        ),
      ),
    );
  });

  test('maps a full Drive to a readable message', () async {
    final client = clientFor(
      (_) async => http.Response(
        jsonEncode({
          'error': {
            'code': 403,
            'message': 'The user has exceeded their Drive storage quota',
            'errors': [
              {'reason': 'storageQuotaExceeded'},
            ],
          },
        }),
        403,
      ),
    );

    await expectLater(
      client.uploadFile(name: 'x', bytes: const [1]),
      throwsA(
        isA<DriveApiException>()
            .having((error) => error.reason, 'reason', 'storageQuotaExceeded')
            .having((error) => error.message, 'message', contains('full')),
      ),
    );
  });

  test('deleting a missing file succeeds', () async {
    final client = clientFor((request) async {
      expect(request.method, 'DELETE');
      return http.Response('', 404);
    });

    await client.deleteFile('gone');
  });

  test('no token means the user must sign in again', () async {
    final client = DriveApiClient(
      client: MockClient((_) async => http.Response('{}', 200)),
      tokenProvider: ({bool forceRefresh = false}) async => null,
    );

    await expectLater(
      client.listFiles(),
      throwsA(isA<DriveApiException>()),
    );
  });

  test('reads the signed-in user', () async {
    final client = clientFor(
      (request) async {
        expect(request.url.path, '/drive/v3/about');
        return http.Response(
          jsonEncode({
            'user': {'emailAddress': 'me@example.com', 'displayName': 'Me'},
          }),
          200,
        );
      },
    );

    final user = await client.getUser();

    expect(user.email, 'me@example.com');
    expect(user.displayName, 'Me');
  });
}
