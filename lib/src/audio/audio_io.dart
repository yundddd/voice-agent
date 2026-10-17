import 'dart:typed_data';

/// PCM16 little-endian bytes (from the mic) -> mono float32 in [-1, 1].
Float32List pcm16ToFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Mono float32 -> 16-bit PCM WAV file bytes (for playback).
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final byteRate = sampleRate * 2;
  final out = ByteData(44 + samples.length * 2);

  void writeString(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  out.setUint32(4, 36 + samples.length * 2, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  out.setUint32(16, 16, Endian.little); // fmt chunk size
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, byteRate, Endian.little);
  out.setUint16(32, 2, Endian.little); // block align
  out.setUint16(34, 16, Endian.little); // bits
  writeString(36, 'data');
  out.setUint32(40, samples.length * 2, Endian.little);

  var o = 44;
  for (final s in samples) {
    final v = (s.clamp(-1.0, 1.0) * 32767).round();
    out.setInt16(o, v, Endian.little);
    o += 2;
  }
  return out.buffer.asUint8List();
}

/// Minimal mono PCM WAV reader (8/16/24/32-bit) for test fixtures.
(Float32List samples, int sampleRate) decodeWav(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes([
    data.getUint8(o),
    data.getUint8(o + 1),
    data.getUint8(o + 2),
    data.getUint8(o + 3),
  ]);
  assert(tag(0) == 'RIFF' && tag(8) == 'WAVE');

  var offset = 12;
  int? bitsPerSample;
  int? sampleRate;
  Uint8List? pcm;
  while (offset + 8 <= bytes.length) {
    final size = data.getUint32(offset + 4, Endian.little);
    switch (tag(offset)) {
      case 'fmt ':
        final channels = data.getUint16(offset + 10, Endian.little);
        assert(channels == 1, 'expected mono wav');
        sampleRate = data.getUint32(offset + 12, Endian.little);
        bitsPerSample = data.getUint16(offset + 22, Endian.little);
      case 'data':
        pcm = Uint8List.sublistView(bytes, offset + 8, offset + 8 + size);
    }
    offset += 8 + size + (size.isOdd ? 1 : 0);
  }
  if (pcm == null || bitsPerSample == null) {
    throw FormatException('Unsupported wav file');
  }

  final n = pcm.length ~/ (bitsPerSample ~/ 8);
  final out = Float32List(n);
  final view = ByteData.sublistView(pcm);
  switch (bitsPerSample) {
    case 16:
      for (var i = 0; i < n; i++) {
        out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
      }
    case 32:
      for (var i = 0; i < n; i++) {
        out[i] = view.getInt32(i * 4, Endian.little) / 2147483648.0;
      }
    default:
      throw FormatException('Unsupported bit depth: $bitsPerSample');
  }
  return (out, sampleRate!);
}
