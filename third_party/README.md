# Vendored packages

## piper_phonemize (fork of csukuangfj/piper-phonemize dart package 1.5.7)

The published package bundles the FULL 19 MB espeak-ng-data (every
language on Earth) plus an 18 MB web WASM bundle. The APK grew past the
Telegram bot's 50 MB upload cap the moment we added it, so this copy is
pruned to what the app can actually speak:

- `espeak-ng-data/lang/`: only `gmw/` (English lives inside the West
  Germanic group) and `roa/` (Italian, for the two Italian student
  voices) survive.
- `espeak-ng-data/*_dict`: every dictionary ≥ 60 KB except `en_dict`
  and `it_dict` deleted (Russian alone was 8.3 MB).
- `assets/web/`: dropped entirely — WASM is for the web target, which
  this app does not build. (A web build would need this directory
  restored from upstream.)
- `example/`: dropped.
- The matching `assets:` entries were removed from this copy's
  pubspec.yaml (a declared-but-missing asset fails the bundle).

To re-sync with an upstream release: copy the new package over this
directory, then repeat the prune (delete every `lang/<group>` except
`gmw` and `roa`, delete big `*_dict` except en/it, delete
`assets/web` and `example`, and strip the corresponding asset lines),
and bump the comment/version in the app's pubspec.

The piper_phonemize extraction code silently skips bundle keys that are
missing, so pruning can never crash a voice — at worst an untested
language voice phonemizes to nothing until its data is restored.
