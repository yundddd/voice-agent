import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// C signatures of the bridge (neutts/bridge/src/lib.rs).
typedef _SetDataPath = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _SetDataPathFn = void Function(ffi.Pointer<ffi.Char>);
typedef _EngineNew =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _EngineNewFn =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _SetSeed = ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _SetSeedFn = int Function(ffi.Pointer<ffi.Void>, int);
typedef _SetRefFile =
    ffi.Int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _SetRefFileFn =
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _Synth =
    ffi.Pointer<ffi.Float> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Size>,
    );
typedef _SynthFn =
    ffi.Pointer<ffi.Float> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Size>,
    );
typedef _FreeAudio = ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Size);
typedef _FreeAudioFn = void Function(ffi.Pointer<ffi.Float>, int);
typedef _EngineFree = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _EngineFreeFn = void Function(ffi.Pointer<ffi.Void>);
typedef _SampleRate = ffi.Int Function();
typedef _SampleRateFn = int Function();
typedef _LastError = ffi.Pointer<ffi.Char> Function();
typedef _LastErrorFn = ffi.Pointer<ffi.Char> Function();

/// Dart FFI wrapper around `libneutts_bridge.so` (neutts/bridge/), the C bridge
/// over the pure-Rust NeuTTS stack: a llama.cpp GGUF backbone, a pure-Rust
/// NeuCodec decoder, and a bundled espeak-ng phonemizer.
///
/// The library is packaged in the APK's jniLibs (arm64) and opened by name on
/// Android; host tests pass an absolute [libPath] instead.
///
/// All NeuTTS inference happens on the calling thread, so this must be used
/// from the speech worker isolate — never the UI isolate.
class NeuttsEngine {
  static ffi.DynamicLibrary? _lib;

  // One dlopen per process: shared by every engine instance.
  static ffi.DynamicLibrary _load(String libPath) =>
      _lib ??= ffi.DynamicLibrary.open(_prepare(libPath));

  /// Makes a pack-installed bridge loadable on Android, then returns the path
  /// to open. Two rules bite for `.so` files living in the app data dir:
  /// * Android enforces W^X on dynamically loaded code: a still-*writable*
  ///   mapping cannot be executable, and our download leaves the files
  ///   owner-writable -> chmod 555 first.
  /// * The bridge's `libc++_shared.so` NEEDED must resolve next to it;
  ///   dlopen'ing that file by absolute path first makes the linker reuse
  ///   the already-loaded instance (by soname) instead of searching system
  ///   namespaces, where the platform copy is not exported to apps.
  /// Host builds link neither knob into play; both steps are no-ops there.
  static String _prepare(String libPath) {
    if (Platform.isAndroid && libPath.isNotEmpty) {
      final dir = p.dirname(libPath);
      for (final name in const ['libneutts_bridge.so', 'libc++_shared.so']) {
        final f = File(p.join(dir, name));
        if (f.existsSync()) {
          try {
            Process.runSync('chmod', ['555', f.path]);
          } on ProcessException {
            // Best effort: older Androids happily dlopen writable files.
          }
        }
      }
      final cpp = File(p.join(dir, 'libc++_shared.so'));
      if (cpp.existsSync()) ffi.DynamicLibrary.open(cpp.path);
    }
    return libPath.isNotEmpty ? libPath : 'libneutts_bridge.so';
  }

  // All function pointers are resolved once, in the constructor body (the
  // loaded library lives in [_lib]).
  late final _SetDataPathFn _setEspeakDataPath;
  late final _EngineNewFn _engineNew;
  late final _SetSeedFn _setSeed;
  late final _SetRefFileFn _setRefFile;
  late final _SynthFn _synthNative;
  late final _FreeAudioFn _freeAudio;
  late final _EngineFreeFn _engineFree;
  late final _SampleRateFn _sampleRate;
  late final _LastErrorFn _lastError;

  ffi.Pointer<ffi.Void> _handle;

  /// Output sample rate of [synth] (Hz), read from the bridge.
  late final int sampleRate;

  /// Number of preset reference voices (drives the UI voice-style slider).
  final int refCount;

  /// The bridge's last error message, or null if none was recorded.
  String? get lastError {
    final e = _lastError();
    return e.address == 0 ? null : e.cast<Utf8>().toDartString();
  }

  Never _fail(String what) =>
      throw StateError('$what: ${lastError ?? 'no bridge error recorded'}');

  /// Opens the bridge, loads the model pair, and selects preset voice [sid].
  ///
  /// * [gguf] — NeuTTS GGUF backbone; [decoder] — NeuCodec decoder safetensors.
  /// * [voicesDir] + [refNames] — preset voices: `<name>.npy` encoded
  ///   reference codes plus `<name>.txt` their transcript, as shipped in the
  ///   voice pack. [sid] picks one; the count goes to [refCount].
  /// * [espeakDir] — app-writable directory the phonemizer unpacks its
  ///   bundled data into (Android's temp dir is not writable).
  /// * [libPath] — non-empty opens that file (host probes); empty dlopens the
  ///   APK-packaged `libneutts_bridge.so`.
  /// * [seed] — pins the sampler seed so the first utterance after load is
  ///   reproducible; null keeps upstream behaviour (random per synth).
  NeuttsEngine({
    required String gguf,
    required String decoder,
    required String voicesDir,
    required List<String> refNames,
    required int sid,
    String lang = 'en-us',
    String espeakDir = '',
    String libPath = '',
    int? seed,
  }) : refCount = refNames.length,
       _handle = ffi.nullptr {
    if (refNames.isEmpty) throw StateError('neutts: no reference voices');
    final dylib = _load(libPath);
    _setEspeakDataPath = dylib.lookupFunction<_SetDataPath, _SetDataPathFn>(
      'nt_set_espeak_data_path',
    );
    _engineNew = dylib.lookupFunction<_EngineNew, _EngineNewFn>(
      'nt_engine_new',
    );
    _setSeed = dylib.lookupFunction<_SetSeed, _SetSeedFn>('nt_engine_set_seed');
    _setRefFile = dylib.lookupFunction<_SetRefFile, _SetRefFileFn>(
      'nt_engine_set_reference_file',
    );
    _synthNative = dylib.lookupFunction<_Synth, _SynthFn>('nt_synth');
    _freeAudio = dylib.lookupFunction<_FreeAudio, _FreeAudioFn>(
      'nt_free_audio',
    );
    _engineFree = dylib.lookupFunction<_EngineFree, _EngineFreeFn>(
      'nt_engine_free',
    );
    _lastError = dylib.lookupFunction<_LastError, _LastErrorFn>(
      'nt_last_error',
    );
    _sampleRate = dylib.lookupFunction<_SampleRate, _SampleRateFn>(
      'nt_sample_rate',
    );
    sampleRate = _sampleRate();
    final dir = espeakDir.isNotEmpty ? espeakDir : Directory.systemTemp.path;
    Directory(dir).createSync(recursive: true);
    final dirPtr = dir.toNativeUtf8();
    _setEspeakDataPath(dirPtr.cast());
    calloc.free(dirPtr);

    final ggufPtr = gguf.toNativeUtf8();
    final decoderPtr = decoder.toNativeUtf8();
    final langPtr = lang.toNativeUtf8();
    final h = _engineNew(ggufPtr.cast(), decoderPtr.cast(), langPtr.cast());
    calloc.free(ggufPtr);
    calloc.free(decoderPtr);
    calloc.free(langPtr);
    if (h.address == 0) _fail('neutts engine load failed');
    _handle = h;
    if (seed != null) {
      final rc = _setSeed(h, seed);
      if (rc != 0) {
        _engineFree(_handle);
        _handle = ffi.nullptr;
        _fail('neutts set_seed failed');
      }
    }

    final name = refNames[sid.clamp(0, refNames.length - 1)];
    final npyPtr = p.join(voicesDir, '$name.npy').toNativeUtf8();
    final txtPtr = p.join(voicesDir, '$name.txt').toNativeUtf8();
    final rc = _setRefFile(_handle, npyPtr.cast(), txtPtr.cast());
    calloc.free(npyPtr);
    calloc.free(txtPtr);
    if (rc != 0) {
      _engineFree(_handle);
      _handle = ffi.nullptr;
      _fail('neutts reference "$name" not loaded');
    }
  }

  /// Synthesize [text] in the selected preset voice.
  /// Returns mono PCM + [sampleRate]; throws StateError with the bridge's
  /// full error chain on failure.
  (Float32List, int) synth(String text) {
    final len = calloc<ffi.Size>();
    final textPtr = text.toNativeUtf8();
    final pcm = _synthNative(_handle, textPtr.cast(), len);
    calloc.free(textPtr);
    if (pcm.address == 0) {
      final err = lastError;
      calloc.free(len);
      throw StateError('neutts synth failed: ${err ?? 'no error recorded'}');
    }
    final n = len.value;
    calloc.free(len);
    // Copy out before returning the buffer to Rust: a Float32List view over
    // the native byte view, then an owned heap copy.
    final bytes = pcm.cast<ffi.Int8>().asTypedList(n * 4);
    final samples = Float32List.fromList(Float32List.view(bytes.buffer, 0, n));
    _freeAudio(pcm, n);
    return (samples, sampleRate);
  }

  /// Release the native engine (safe to call once only).
  void free() {
    if (_handle.address != 0) {
      _engineFree(_handle);
      _handle = ffi.nullptr;
    }
  }
}
