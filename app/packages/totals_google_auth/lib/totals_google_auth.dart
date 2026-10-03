import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// An OAuth access token granted by the user's Google account.
class GoogleAuthorization {
  final String accessToken;
  final List<String> grantedScopes;

  /// The account email, when Google shares it with the authorization.
  final String? email;

  const GoogleAuthorization({
    required this.accessToken,
    this.grantedScopes = const [],
    this.email,
  });
}

class GoogleAuthException implements Exception {
  final String code;
  final String message;

  const GoogleAuthException(this.code, this.message);

  @override
  String toString() => message;
}

/// Requests Google OAuth scopes through Google Play services.
///
/// Works without an activity (for example in a WorkManager isolate) as long
/// as the user granted the scopes before; only the consent screen needs one.
class TotalsGoogleAuth {
  TotalsGoogleAuth._();

  @visibleForTesting
  static const MethodChannel channel =
      MethodChannel('detached.totals/google_auth');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Returns a token for [scopes], or null when the user has not granted
  /// them and [interactive] is false, or the user cancelled the consent
  /// screen.
  static Future<GoogleAuthorization?> authorize({
    required List<String> scopes,
    bool interactive = true,
  }) async {
    if (!isSupported) {
      throw const GoogleAuthException(
        'unsupported',
        'Google Drive backup is only available on Android.',
      );
    }
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'authorize',
        <String, dynamic>{
          'scopes': scopes,
          'interactive': interactive,
        },
      );
      if (result == null) return null;
      final token = result['accessToken'] as String?;
      if (token == null || token.isEmpty) return null;
      final email = (result['email'] as String?)?.trim();
      return GoogleAuthorization(
        accessToken: token,
        grantedScopes: List<String>.from(
          result['grantedScopes'] as List? ?? const <String>[],
        ),
        email: email == null || email.isEmpty ? null : email,
      );
    } on PlatformException catch (error) {
      throw GoogleAuthException(
        error.code,
        error.message ?? 'Google sign-in failed.',
      );
    }
  }

  /// Drops [accessToken] from the Play services cache so the next
  /// [authorize] call returns a fresh one.
  static Future<void> clearToken(String accessToken) async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>(
        'clearToken',
        <String, dynamic>{'token': accessToken},
      );
    } on PlatformException catch (error) {
      throw GoogleAuthException(
        error.code,
        error.message ?? 'Could not refresh the Google token.',
      );
    }
  }
}
