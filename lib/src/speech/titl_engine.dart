// Teacher-in-the-loop (MithrilMan/teacher-in-the-loop): an 8M-parameter
// single-voice STUDENT of Kokoro-82M (Paradee architecture), shipped as
// one self-contained ONNX graph. This file runs that graph directly
// against the libonnxruntime.so the sherpa_onnx plugin already ships in
// the APK — no second runtime, no Python, ~9 MB per voice against the
// teacher's 334 MB pack.
//
// The graph's contract (model card): input `input_ids` int64 [1,T] of
// Kokoro phoneme-vocabulary ids (padding id 0 at both ends, T <= 512),
// input `speed` float32 [1]; output `waveform` float32 [1,N] mono at
// 24 kHz — exactly the float PCM the speech worker already relays.
// Phonemes come from Kokoro's own lexicon files via the
// LexiconPronouncer (lib/lexicon_pronouncer.dart) and pass through the
// pack's vocab.json; characters the vocabulary does not carry are
// dropped, never guessed. (The front-end used to be espeak-ng and this
// file carried its fold tables; the lexicon needs none — it is the
// trained alphabet already.)
//
// OrtApi vtable offsets: parsed from the ONNX Runtime 1.28.2 C header
// (microsoft/onnxruntime tag v1.28.2, onnxruntime_c_api.h). Every struct
// field — ORT_API2_STATUS, ORT_API_T, ORT_CLASS_RELEASE and the raw
// function-pointer members — occupies exactly one pointer slot in
// declaration order (GetErrorCode at 8 proves the slots are dense), and
// GetApi(v) hands back this same struct for any version the library
// supports: the ABI only ever APPENDS, so the offsets below hold for
// whatever ORT a future sherpa bundles, provided it is not OLDER than
// the one these were read from.
library;

// Constant names mirror the ORT C API entry points they address.
// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// OrtApi slot offsets (bytes), ORT 1.28.2.
const int _CreateEnv = 24;
const int _CreateSessionOptions = 80;
const int _CreateSession = 56;
const int _CreateCpuMemoryInfo = 552;
const int _CreateTensorWithDataAsOrtValue = 392;
const int _Run = 72;
const int _GetTensorTypeAndShape = 520;
const int _GetTensorShapeElementCount = 512;
const int _GetTensorMutableData = 408;
const int _ReleaseSessionOptions = 800;
const int _ReleaseValue = 768;
const int _ReleaseTensorTypeAndShapeInfo = 792;
const int _GetErrorMessage = 16;

// ONNXTensorElementDataType: FLOAT=1, INT64=7.
const int _dtypeFloat = 1;
const int _dtypeInt64 = 7;

// OrtAllocatorType ORT_DEVICE / OrtMemType DEFAULT — the pairing every
// hand-binding of the C API uses for caller-owned tensor data.
const int _allocDevice = 1;
const int _memTypeDefault = 0;

/// Student-engine failure: a missing graph, a missing lexicon pack, or
/// a freed engine. Phonemes the vocab rejects are not errors — they
/// are dropped, never guessed (see [TitlEngine.phonemesFromWords]).
class TitlException implements Exception {
  final String message;
  TitlException(this.message);
  @override
  String toString() => 'TitlException: $message';
}

Pointer _apiSlot(Pointer api, int byteOffset) =>
    api.cast<Pointer<NativeType>>()[byteOffset ~/ 8];

void _checkStatus(Pointer api, Pointer status, String what) {
  if (status == nullptr) return;
  final msg = _apiSlot(api, _GetErrorMessage)
      .cast<NativeFunction<Pointer<Utf8> Function(Pointer)>>()
      .asFunction<Pointer<Utf8> Function(Pointer)>()(status)
      .toDartString();
  calloc.free(status);
  throw TitlException('$what: $msg');
}

/// One loaded TITL graph + its phoneme vocabulary. Lives on the speech
/// worker isolate — one call site at a time, like the sherpa engine it
/// sits beside.
class TitlEngine {
  static const int maxPhonemes = 510; // T <= 512, minus the two pads
  static const int sampleRate = 24000;

  final Pointer _api;
  // ignore: unused_field
  final Pointer _env; // kept for the future ReleaseEnv
  final Pointer _session;
  final Pointer _memInfo;
  final Map<String, int> vocab;
  bool disposed = false;

  TitlEngine._(this._api, this._env, this._session, this._memInfo, this.vocab);

  /// Load pack files: the graph at [modelPath], vocabulary at
  /// [vocabPath]. Synchronous — the worker isolate already parks the
  /// UI behind engine loads (sherpa does the same on its path).
  factory TitlEngine.load({
    required String modelPath,
    required String vocabPath,
  }) {
    final libName = Platform.isAndroid || Platform.isLinux
        ? 'libonnxruntime.so'
        : Platform.isMacOS || Platform.isIOS
        ? 'libonnxruntime.dylib'
        : 'onnxruntime.dll';
    final lib = DynamicLibrary.open(libName);
    final base = lib.lookupFunction<Pointer Function(), Pointer Function()>(
      'OrtGetApiBase',
    )();
    // OrtApiBase field 0: GetApi(uint32) -> const OrtApi*.
    final api = base
        .cast<Pointer<NativeFunction>>()[0]
        .cast<NativeFunction<Pointer Function(Uint32)>>()
        .asFunction<Pointer Function(int)>()(23);

    final envP = calloc<Pointer>();
    _checkStatus(
      api,
      _apiSlot(api, _CreateEnv)
          .cast<
            NativeFunction<
              Pointer Function(Int32, Pointer<Utf8>, Pointer<Pointer>)
            >
          >()
          .asFunction<Pointer Function(int, Pointer<Utf8>, Pointer<Pointer>)>()(
        2,
        'voice_agent'.toNativeUtf8(),
        envP,
      ),
      'CreateEnv',
    );
    final env = envP.value;
    calloc.free(envP);

    final optsP = calloc<Pointer>();
    _checkStatus(
      api,
      _apiSlot(api, _CreateSessionOptions)
          .cast<NativeFunction<Pointer Function(Pointer<Pointer>)>>()
          .asFunction<Pointer Function(Pointer<Pointer>)>()(optsP),
      'CreateSessionOptions',
    );
    final sessP = calloc<Pointer>();
    _checkStatus(
      api,
      _apiSlot(api, _CreateSession)
          .cast<
            NativeFunction<
              Pointer Function(
                Pointer,
                Pointer<Utf8>,
                Pointer,
                Pointer<Pointer>,
              )
            >
          >()
          .asFunction<
            Pointer Function(Pointer, Pointer<Utf8>, Pointer, Pointer<Pointer>)
          >()(env, modelPath.toNativeUtf8(), optsP.value, sessP),
      'CreateSession $modelPath',
    );
    final session = sessP.value;
    calloc.free(sessP);
    _apiSlot(api, _ReleaseSessionOptions)
        .cast<NativeFunction<Void Function(Pointer)>>()
        .asFunction<void Function(Pointer)>()(optsP.value);
    calloc.free(optsP);

    final miP = calloc<Pointer>();
    _checkStatus(
      api,
      _apiSlot(api, _CreateCpuMemoryInfo)
          .cast<
            NativeFunction<Pointer Function(Int32, Int32, Pointer<Pointer>)>
          >()
          .asFunction<Pointer Function(int, int, Pointer<Pointer>)>()(
        _allocDevice,
        _memTypeDefault,
        miP,
      ),
      'CreateCpuMemoryInfo',
    );
    final memInfo = miP.value;
    calloc.free(miP);

    final vocab = <String, int>{
      for (final e
          in (jsonDecode(File(vocabPath).readAsStringSync())
                  as Map<String, Object?>)
              .entries)
        e.key: (e.value as num).toInt(),
    };
    return TitlEngine._(api, env, session, memInfo, vocab);
  }

  // ── Pure text plumbing (unit-tested without any native) ───────────────

  /// Word phonemes (code points per word, the shape both the lexicon
  /// pronouncer and the retired piper plugin produced) → one Kokoro
  /// phoneme string: foreign chars dropped against [vocab], words
  /// joined on the vocab's own space char, and a final stop added when
  /// the piece lost one (sentence intonation, like the teacher's own
  /// pipeline feeds it). Pure; unit-tested.
  static String phonemesFromWords(List<List<int>> words, Set<String> vocab) {
    final b = StringBuffer();
    for (final w in words) {
      for (final rune in w) {
        final c = String.fromCharCode(rune);
        if (vocab.contains(c)) b.write(c);
      }
      b.write(' ');
    }
    // +343: fold BEFORE the stop rule — a piece ending on ';' becomes
    // the ',.' tail a comma-cut piece already ships today (the lead
    // cut hands one over every few replies), a proven-good shape. The
    // rule itself stays the teacher's: any trained stop stands down.
    var s = breathe(b.toString().trimRight());
    if (s.isNotEmpty && !RegExp(r'[.!?,;:]$').hasMatch(s)) s += '.';
    return s;
  }

  /// Phoneme string → padded id runs. Unknown chars drop; overlong
  /// lines split at the last space within budget (the graph caps T at
  /// 512 including both pads). Pure; unit-tested.
  static List<List<int>> idsFromPhonemes(
    String phonemes,
    Map<String, int> vocab,
  ) {
    final ids = [
      for (final c in phonemes.split(''))
        if (vocab.containsKey(c)) vocab[c]!,
    ];
    if (ids.length <= maxPhonemes) {
      return [
        [0, ...ids, 0],
      ];
    }
    final space = vocab[' '] ?? 16;
    final runs = <List<int>>[];
    var rest = ids;
    while (rest.length > maxPhonemes - 2) {
      var cut = maxPhonemes - 2;
      while (cut > 8 && rest[cut] != space) {
        cut--;
      }
      runs.add([0, ...rest.sublist(0, cut + 1), 0]);
      rest = rest.sublist(cut + 1);
    }
    runs.add([0, ...rest, 0]);
    return runs;
  }

  // ── Inference ──────────────────────────────────────────────────────────

  /// The +343 breath fold: semicolons, colons, dashes and ellipses are
  /// IN the trained alphabet (the teacher's pipeline feeds them through)
  /// but an 8M student distills them to nearly nothing — the field ear
  /// heard '…; next word' run together. The comma is the break the
  /// Misaki training data floods, so every rarer breath mark folds onto
  /// it before the graph sees a codepoint. Periods, bangs, question
  /// marks and commas ride untouched; applied inside [synth] so BOTH
  /// front ends — lexicon ladder and espeak fallback — pass this one
  /// gate. Pure; unit-tested.
  static String breathe(String phonemes) {
    for (final m in const [';', ':', '—', '–', '…'].indexed) {
      phonemes = phonemes.replaceAll(m.$2, ',');
    }
    return phonemes;
  }

  /// One sentence of Kokoro phonemes (as [phonemesFromWords] emits) to
  /// 24 kHz float PCM. Overlong lines run as several graph calls glued
  /// back-to-back.
  Float32List synth(String phonemes, {double speed = 1.0}) {
    if (disposed) throw TitlException('engine freed');
    phonemes = breathe(phonemes); // +343: rare breaths become trained ones
    final tensor = _apiSlot(_api, _CreateTensorWithDataAsOrtValue)
        .cast<
          NativeFunction<
            Pointer Function(
              Pointer,
              Pointer,
              IntPtr,
              Pointer<Int64>,
              IntPtr,
              Int32,
              Pointer<Pointer>,
            )
          >
        >()
        .asFunction<
          Pointer Function(
            Pointer,
            Pointer,
            int,
            Pointer<Int64>,
            int,
            int,
            Pointer<Pointer>,
          )
        >();
    final run = _apiSlot(_api, _Run)
        .cast<
          NativeFunction<
            Pointer Function(
              Pointer,
              Pointer,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer>,
              IntPtr,
              Pointer<Pointer<Utf8>>,
              IntPtr,
              Pointer<Pointer>,
            )
          >
        >()
        .asFunction<
          Pointer Function(
            Pointer,
            Pointer,
            Pointer<Pointer<Utf8>>,
            Pointer<Pointer>,
            int,
            Pointer<Pointer<Utf8>>,
            int,
            Pointer<Pointer>,
          )
        >();
    final shapeInfo = _apiSlot(_api, _GetTensorTypeAndShape)
        .cast<NativeFunction<Pointer Function(Pointer, Pointer<Pointer>)>>()
        .asFunction<Pointer Function(Pointer, Pointer<Pointer>)>();
    final elemCount = _apiSlot(_api, _GetTensorShapeElementCount)
        .cast<NativeFunction<Pointer Function(Pointer, Pointer<IntPtr>)>>()
        .asFunction<Pointer Function(Pointer, Pointer<IntPtr>)>();
    final tensorData = _apiSlot(_api, _GetTensorMutableData)
        .cast<NativeFunction<Pointer Function(Pointer, Pointer<Pointer>)>>()
        .asFunction<Pointer Function(Pointer, Pointer<Pointer>)>();
    final releaseValue = _apiSlot(_api, _ReleaseValue)
        .cast<NativeFunction<Void Function(Pointer)>>()
        .asFunction<void Function(Pointer)>();
    final releaseInfo = _apiSlot(_api, _ReleaseTensorTypeAndShapeInfo)
        .cast<NativeFunction<Void Function(Pointer)>>()
        .asFunction<void Function(Pointer)>();

    final pieces = <Float32List>[];
    var total = 0;
    for (final ids in idsFromPhonemes(phonemes, vocab)) {
      final data = calloc<Int64>(ids.length);
      for (var i = 0; i < ids.length; i++) {
        data[i] = ids[i];
      }
      final shape = calloc<Int64>(2);
      shape[0] = 1;
      shape[1] = ids.length;
      final idsV = calloc<Pointer>();
      _checkStatus(
        _api,
        tensor(
          _memInfo,
          data.cast(),
          ids.length * 8,
          shape,
          2,
          _dtypeInt64,
          idsV,
        ),
        'CreateTensor(input_ids)',
      );
      final speedBuf = calloc<Float>(1);
      speedBuf[0] = speed;
      final speedShape = calloc<Int64>(1);
      speedShape[0] = 1;
      final speedV = calloc<Pointer>();
      _checkStatus(
        _api,
        tensor(
          _memInfo,
          speedBuf.cast(),
          4,
          speedShape,
          1,
          _dtypeFloat,
          speedV,
        ),
        'CreateTensor(speed)',
      );
      final names = calloc<Pointer<Utf8>>(2);
      names[0] = 'input_ids'.toNativeUtf8();
      names[1] = 'speed'.toNativeUtf8();
      final inputs = calloc<Pointer>(2);
      inputs[0] = idsV.value;
      inputs[1] = speedV.value;
      final outName = calloc<Pointer<Utf8>>(1);
      outName[0] = 'waveform'.toNativeUtf8();
      final output = calloc<Pointer>();
      _checkStatus(
        _api,
        run(_session, nullptr, names, inputs, 2, outName, 1, output),
        'Run',
      );

      final infoP = calloc<Pointer>();
      _checkStatus(
        _api,
        shapeInfo(output.value, infoP),
        'GetTensorTypeAndShape',
      );
      final countP = calloc<IntPtr>();
      _checkStatus(
        _api,
        elemCount(infoP.value, countP),
        'GetShapeElementCount',
      );
      final n = countP.value;
      final dataP = calloc<Pointer>();
      _checkStatus(
        _api,
        tensorData(output.value, dataP),
        'GetTensorMutableData',
      );
      pieces.add(
        Float32List.fromList(dataP.value.cast<Float>().asTypedList(n)),
      );
      total += n;

      releaseInfo(infoP.value);
      calloc.free(infoP);
      calloc.free(countP);
      calloc.free(dataP);
      calloc.free(output);
      releaseValue(idsV.value);
      releaseValue(speedV.value);
      calloc.free(idsV);
      calloc.free(speedV);
      calloc.free(shape);
      calloc.free(speedShape);
      calloc.free(data);
      calloc.free(speedBuf);
      calloc.free(names);
      calloc.free(outName);
      calloc.free(inputs);
    }

    final out = Float32List(total);
    var at = 0;
    for (final p in pieces) {
      out.setRange(at, at + p.length, p);
      at += p.length;
    }
    return out;
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    // Env/session deliberately leak for now: a voice switch shouldn't
    // race an in-flight Run, and the worker frees the whole isolate's
    // engines only at process teardown. (ReleaseSession waits until we
    // support hot voice swaps inside one worker lifetime.)
  }
}
