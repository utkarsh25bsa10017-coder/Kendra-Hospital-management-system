import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../data/record.dart';

/// Work factor for new password hashes. Tests lower it to stay fast.
int defaultPasswordIterations = 60000;

/// PBKDF2-HMAC-SHA256, 32-byte key, hex encoded.
String hashPassword(String password, String saltHex, int iterations) {
  final hmac = Hmac(sha256, utf8.encode(password));
  final salt = _hexToBytes(saltHex);
  final block = Uint8List(salt.length + 4)
    ..setAll(0, salt)
    ..setAll(salt.length, const [0, 0, 0, 1]);
  var u = Uint8List.fromList(hmac.convert(block).bytes);
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

({String hash, String salt, int iterations}) newPasswordHash(String password,
    {int? iterations}) {
  final it = iterations ?? defaultPasswordIterations;
  final salt = randomToken(16);
  return (hash: hashPassword(password, salt, it), salt: salt, iterations: it);
}

bool verifyPassword(String password, String hash, String salt, int iterations) {
  final h = hashPassword(password, salt, iterations);
  if (h.length != hash.length) return false;
  var diff = 0;
  for (var i = 0; i < h.length; i++) {
    diff |= h.codeUnitAt(i) ^ hash.codeUnitAt(i);
  }
  return diff == 0;
}

/// Returns an error message, or null if the password is acceptable.
String? passwordProblem(String password) {
  if (password.length < 8) return 'Use at least 8 characters';
  if (!RegExp(r'[A-Za-z]').hasMatch(password) || !RegExp(r'[0-9]').hasMatch(password)) {
    return 'Use letters and at least one number';
  }
  return null;
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
