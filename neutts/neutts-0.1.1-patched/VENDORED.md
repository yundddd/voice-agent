# neutts 0.1.1 (vendored, patched)

Copy of crates.io `neutts` 0.1.1 (MIT, eugenehp/neutts-rs) for the early-EOS
suppression patch in `src/backbone.rs` (search VENDORED PATCH). Wired in via
`[patch.crates-io]` in ../bridge/Cargo.toml. Review with:

    diff -ru ~/.cargo/registry/src/*/neutts-0.1.1 neutts/neutts-0.1.1-patched
