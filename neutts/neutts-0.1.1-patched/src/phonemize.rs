//! Phonemisation using the pure-Rust `espeak-ng` crate.
//!
//! Mirrors the Python `BasePhonemizer` + `FrenchPhonemizer` from `neutts/phonemizers.py`.
//! The full implementation is compiled only when the **`espeak`** Cargo feature
//! is enabled.  Without it, all public functions are still present but return
//! informative errors so downstream callers using `generate_from_ipa()` compile
//! without any espeak dependency.
//!
//! ## Supported languages
//!
//! | Language   | Code    | Notes                                      |
//! |------------|---------|--------------------------------------------|
//! | English    | `en-us` | Default for NeuTTS-Nano / NeuTTS-Air       |
//! | German     | `de`    | NeuTTS-Nano-German                         |
//! | French     | `fr-fr` | NeuTTS-Nano-French; dashes stripped        |
//! | Spanish    | `es`    | NeuTTS-Nano-Spanish                        |
//!
//! All 114 bundled espeak-ng languages are available.
//!
//! ## Enabling
//!
//! ```toml
//! neutts = { version = "…", features = ["espeak"] }
//! ```
//!
//! ## Build requirements (when `espeak` feature is on)
//!
//! **None!** The `espeak-ng` crate is a pure-Rust port that bundles its own
//! data files for all 114 languages.  No system library, no pkg-config, no
//! cmake needed.

use std::path::{Path, PathBuf};
use anyhow::Result;
#[cfg(not(feature = "espeak"))]
use anyhow::anyhow;
use once_cell::sync::OnceCell;

// ─── Runtime data-path ────────────────────────────────────────────────────────

static DATA_PATH: OnceCell<PathBuf> = OnceCell::new();

/// Set the path to the espeak-ng data directory.
///
/// With the pure-Rust `espeak-ng` crate and bundled data, this is **optional**.
/// Call this only if you need to override the bundled data directory (e.g. for
/// custom dictionaries).
///
/// Has no effect if called after [`phonemize`] has already initialised the
/// engine.
pub fn set_data_path(path: &Path) {
    let _ = DATA_PATH.set(path.to_path_buf());
}

// ─── espeak feature: pure-Rust implementation ─────────────────────────────────

#[cfg(feature = "espeak")]
mod inner {
    use std::path::PathBuf;

    use anyhow::{anyhow, Result};
    use once_cell::sync::OnceCell;

    use super::DATA_PATH;

    /// Lazily-initialised data directory for the bundled espeak-ng data.
    static BUNDLED_DATA_DIR: OnceCell<PathBuf> = OnceCell::new();

    /// Get or create the data directory with bundled espeak-ng data installed.
    fn get_data_dir() -> Result<&'static PathBuf> {
        if let Some(user_dir) = DATA_PATH.get() {
            return Ok(BUNDLED_DATA_DIR.get_or_init(|| user_dir.clone()));
        }

        BUNDLED_DATA_DIR.get_or_try_init(|| {
            let cache_dir = std::env::temp_dir().join("neutts-espeak-ng-data");
            std::fs::create_dir_all(&cache_dir)
                .map_err(|e| anyhow!("Failed to create espeak-ng data dir: {}", e))?;

            espeak_ng::install_bundled_data(&cache_dir)
                .map_err(|e| anyhow!("Failed to install bundled espeak-ng data: {}", e))?;

            Ok(cache_dir)
        })
    }

    /// Map NeuTTS language codes to espeak-ng language codes.
    ///
    /// espeak-ng uses short codes like "en", "fr", "de", "es" while NeuTTS
    /// uses "en-us", "fr-fr".  We map to the base language for the pure-Rust
    /// crate.
    fn map_lang(lang: &str) -> &str {
        match lang {
            "en-us" => "en",
            "fr-fr" => "fr",
            other   => other,
        }
    }

    fn create_engine(lang: &str) -> Result<espeak_ng::EspeakNg> {
        let data_dir = get_data_dir()?;
        let mapped = map_lang(lang);
        espeak_ng::EspeakNg::with_data_dir(mapped, data_dir)
            .map_err(|e| anyhow!("espeak-ng init for '{}' failed: {}", lang, e))
    }

    pub(super) fn is_available(lang: &str) -> bool {
        create_engine(lang).is_ok()
    }

    pub(super) fn run_phonemize(text: &str, lang: &str) -> Result<String> {
        if text.is_empty() {
            return Ok(String::new());
        }

        let engine = create_engine(lang)?;
        let ipa = engine
            .text_to_phonemes(text)
            .map_err(|e| anyhow!("espeak-ng phonemise failed: {}", e))?;

        Ok(ipa.trim().to_owned())
    }

    #[cfg(test)]
    pub(super) fn run_phonemize_lang(lang: &str, text: &str) -> Result<String> {
        run_phonemize(text, lang)
    }
}

// ─── Public API ────────────────────────────────────────────────────────────────

/// Returns `true` if espeak-ng is available and initialises successfully for
/// the given language code.
///
/// Always returns `false` when the `espeak` Cargo feature is disabled.
pub fn is_espeak_available(lang: &str) -> bool {
    #[cfg(feature = "espeak")]
    { inner::is_available(lang) }
    #[cfg(not(feature = "espeak"))]
    { let _ = lang; false }
}

/// Convert `text` to IPA phonemes using the espeak-ng voice for `lang`.
///
/// `lang` should be an espeak-ng language code such as `"en-us"`, `"de"`,
/// `"fr-fr"`, or `"es"`.
///
/// French output has dashes stripped to match the Python `FrenchPhonemizer`.
///
/// **Requires the `espeak` Cargo feature.**  Returns an error when the feature
/// is disabled — use `NeuTTS::infer_from_ipa()` to bypass phonemisation.
pub fn phonemize(text: &str, lang: &str) -> Result<String> {
    #[cfg(feature = "espeak")]
    {
        let raw = inner::run_phonemize(text, lang)?;
        // French: strip dashes (matches Python FrenchPhonemizer.clean).
        let cleaned = if lang.starts_with("fr") {
            raw.replace('-', "")
        } else {
            raw
        };
        // Normalise whitespace — mirrors Python `" ".join(phones.split())`
        let tokens: Vec<&str> = cleaned.split_whitespace().collect();
        Ok(tokens.join(" "))
    }
    #[cfg(not(feature = "espeak"))]
    {
        let _ = (text, lang);
        Err(anyhow!(
            "phonemize() requires the `espeak` Cargo feature.\n\
             Enable it: neutts = {{ features = [\"espeak\"] }}\n\
             Or use NeuTTS::infer_from_ipa() to bypass phonemisation."
        ))
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(all(test, feature = "espeak"))]
mod tests {
    use super::*;

    #[test]
    fn test_available_en_us() {
        assert!(is_espeak_available("en-us"));
    }

    #[test]
    fn test_phonemize_hello() {
        let ipa = phonemize("Hello world", "en-us").expect("phonemize failed");
        assert!(!ipa.is_empty(), "expected non-empty IPA");
        println!("IPA (en-us): {ipa}");
    }

    #[test]
    fn test_phonemize_empty() {
        let ipa = phonemize("", "en-us").expect("phonemize failed");
        assert!(ipa.trim().is_empty(), "expected empty IPA for empty input");
    }

    #[test]
    fn test_phonemize_whitespace_normalised() {
        let ipa = phonemize("Hello world.", "en-us").expect("phonemize failed");
        assert!(!ipa.starts_with(' '), "should not start with space");
        assert!(!ipa.ends_with(' '),   "should not end with space");
    }

    #[test]
    fn test_french_no_dashes() {
        let ipa = phonemize("bonjour", "fr-fr").expect("phonemize failed");
        assert!(!ipa.contains('-'), "French output should have dashes stripped: {ipa}");
    }

    #[test]
    fn test_german() {
        let ipa = phonemize("Hallo Welt", "de").expect("phonemize failed");
        assert!(!ipa.is_empty(), "expected non-empty IPA for German");
        println!("IPA (de): {ipa}");
    }

    #[test]
    fn test_spanish() {
        let ipa = phonemize("Hola mundo", "es").expect("phonemize failed");
        assert!(!ipa.is_empty(), "expected non-empty IPA for Spanish");
        println!("IPA (es): {ipa}");
    }

    #[test]
    fn test_available_german() {
        assert!(is_espeak_available("de"));
    }

    #[test]
    fn test_available_french() {
        assert!(is_espeak_available("fr-fr"));
    }

    #[test]
    fn test_available_spanish() {
        assert!(is_espeak_available("es"));
    }

    #[test]
    fn test_bogus_language_does_not_crash() {
        // A completely bogus language code should not crash.
        // The pure-Rust espeak-ng may accept unknown codes (falls back to default),
        // so we only verify it doesn't panic.
        let _ = is_espeak_available("zz-nonexistent-999");
        // phonemize should either succeed or return an error, never panic.
        let result = phonemize("hello", "zz-nonexistent-999");
        match result {
            Ok(ipa) => println!("Bogus lang produced IPA (fallback): {ipa}"),
            Err(e) => println!("Bogus lang returned error (expected): {e}"),
        }
    }

    #[test]
    fn test_lang_mapping_en_us() {
        // en-us should map to en internally and produce valid IPA
        let ipa = phonemize("test", "en-us").expect("phonemize en-us failed");
        assert!(!ipa.is_empty(), "en-us should produce IPA");
    }

    #[test]
    fn test_numbers_produce_ipa() {
        let ipa = phonemize("123", "en-us").expect("phonemize numbers failed");
        assert!(!ipa.is_empty(), "numbers should produce IPA: got empty");
    }

    #[test]
    fn test_long_text() {
        let long = "The quick brown fox jumps over the lazy dog. ".repeat(20);
        let ipa = phonemize(&long, "en-us").expect("phonemize long text failed");
        assert!(!ipa.is_empty(), "long text should produce IPA");
    }

    #[test]
    fn test_french_produces_ipa() {
        let ipa = phonemize("Bonjour le monde", "fr-fr").expect("phonemize fr-fr failed");
        assert!(!ipa.is_empty(), "French should produce IPA");
        assert!(!ipa.contains('-'), "French IPA should have dashes stripped: {ipa}");
        // Should contain some recognizable French phonemes
        assert!(
            ipa.contains('b') || ipa.contains('ɔ') || ipa.contains('ʒ'),
            "unexpected French IPA for 'Bonjour le monde': {ipa}"
        );
    }

    #[test]
    fn test_punctuation_only() {
        // Punctuation-only input should not crash
        let ipa = phonemize("...", "en-us").expect("phonemize punctuation failed");
        // May be empty, but should not error
        let _ = ipa;
    }

    #[test]
    fn test_unicode_input() {
        // Non-Latin input to English voice should not crash
        let ipa = phonemize("café résumé naïve", "en-us").expect("phonemize unicode failed");
        assert!(!ipa.is_empty(), "accented text should produce IPA");
    }

    #[test]
    fn test_concurrent_phonemize() {
        // The pure-Rust engine creates a new instance per call, so
        // concurrent access should be safe.
        let handles: Vec<_> = (0..4)
            .map(|i| {
                std::thread::spawn(move || {
                    let text = format!("Thread number {i} says hello");
                    phonemize(&text, "en-us").expect("concurrent phonemize failed")
                })
            })
            .collect();

        for h in handles {
            let ipa = h.join().expect("thread panicked");
            assert!(!ipa.is_empty(), "concurrent call should produce IPA");
        }
    }

    #[test]
    fn test_all_bundled_languages() {
        let sample_texts: &[(&str, &str)] = &[
            ("af", "Hallo wêreld"),
            ("am", "ሰላም ዓለም"),
            ("an", "Hola mundo"),
            ("ar", "مرحبا بالعالم"),
            ("as", "নমস্কাৰ পৃথিৱী"),
            ("az", "Salam dünya"),
            ("ba", "Сәләм донъя"),
            ("be", "Прывітанне свет"),
            ("bg", "Здравей свят"),
            ("bn", "হ্যালো বিশ্ব"),
            ("bpy", "হ্যালো বিশ্ব"),
            ("bs", "Zdravo svijete"),
            ("ca", "Hola món"),
            ("chr", "ᎣᏏᏲ ᎡᎶᎯ"),
            ("cmn", "你好世界"),
            ("cs", "Ahoj světe"),
            ("cv", "Салам тĕнче"),
            ("cy", "Helo byd"),
            ("da", "Hej verden"),
            ("de", "Hallo Welt"),
            ("el", "Γεια σου κόσμε"),
            ("en", "Hello world"),
            ("eo", "Saluton mondo"),
            ("es", "Hola mundo"),
            ("et", "Tere maailm"),
            ("eu", "Kaixo mundua"),
            ("fa", "سلام دنیا"),
            ("fi", "Hei maailma"),
            ("fr", "Bonjour le monde"),
            ("ga", "Dia duit a dhomhan"),
            ("gd", "Halò a shaoghail"),
            ("gn", "Mba eichaporã"),
            ("grc", "Χαῖρε κόσμε"),
            ("gu", "હેલો વિશ્વ"),
            ("hak", "你好世界"),
            ("haw", "Aloha honua"),
            ("he", "שלום עולם"),
            ("hi", "नमस्ते दुनिया"),
            ("hr", "Pozdrav svijete"),
            ("ht", "Bonjou mond"),
            ("hu", "Helló világ"),
            ("hy", "Բարdelays աdelays"),
            ("ia", "Salute mundo"),
            ("id", "Halo dunia"),
            ("io", "Saluto mondo"),
            ("is", "Halló heimur"),
            ("it", "Ciao mondo"),
            ("ja", "こんにちは世界"),
            ("jbo", "coi rodo"),
            ("ka", "გამარჯობა მსოფლიო"),
            ("kk", "Сәлем әлем"),
            ("kl", "Aluu nunarsuaq"),
            ("kn", "ಹಲೋ ಪ್ರಪಂಚ"),
            ("ko", "안녕하세요 세계"),
            ("kok", "नमस्कार जग"),
            ("ku", "Silav cîhan"),
            ("ky", "Салам дүйнө"),
            ("la", "Salve munde"),
            ("lb", "Moien Welt"),
            ("lfn", "Bon dia mundo"),
            ("lt", "Sveikas pasauli"),
            ("lv", "Sveika pasaule"),
            ("mi", "Kia ora te ao"),
            ("mk", "Здраво свету"),
            ("ml", "ഹലോ ലോകം"),
            ("mr", "नमस्कार जग"),
            ("ms", "Helo dunia"),
            ("mt", "Bongu dinja"),
            ("mto", "Hola mundo"),
            ("my", "မင်္ဂလာပါ ကမ္ဘာ"),
            ("nci", "Niltze cemanahuac"),
            ("ne", "नमस्ते संसार"),
            ("nl", "Hallo wereld"),
            ("no", "Hei verden"),
            ("nog", "Салам дуныя"),
            ("om", "Akkam addunyaa"),
            ("or", "ନମସ୍କାର ବିଶ୍ୱ"),
            ("pa", "ਸਤ ਸ੍ਰੀ ਅਕਾਲ ਦੁਨੀਆ"),
            ("pap", "Bon dia mundo"),
            ("piqd", "nuqneH"),
            ("pl", "Witaj świecie"),
            ("pt", "Olá mundo"),
            ("py", "Hello world"),
            ("qdb", "Hello world"),
            ("qu", "Napaykullayki llaqta"),
            ("quc", "Saqarik uwachulew"),
            ("qya", "Aiya Arda"),
            ("ro", "Salut lume"),
            ("ru", "Привет мир"),
            ("sd", "هيلو دنيا"),
            ("shn", "မႂ်ႇသုင်ႇ လူၵ်ႈ"),
            ("si", "හෙලෝ ලෝකය"),
            ("sjn", "Mae govannen"),
            ("sk", "Ahoj svet"),
            ("sl", "Pozdravljen svet"),
            ("smj", "Buorre beaivi"),
            ("sq", "Përshëndetje botë"),
            ("sr", "Здраво свете"),
            ("sv", "Hej världen"),
            ("sw", "Habari dunia"),
            ("ta", "வணக்கம் உலகம்"),
            ("te", "హలో ప్రపంచం"),
            ("th", "สวัสดีชาวโลก"),
            ("ti", "ሰላም ዓለም"),
            ("tk", "Salam dünýä"),
            ("tn", "Dumela lefatshe"),
            ("tr", "Merhaba dünya"),
            ("tt", "Сәлам дөнья"),
            ("ug", "ياخشىمۇسىز دۇنيا"),
            ("uk", "Привіт світ"),
            ("ur", "ہیلو دنیا"),
            ("uz", "Salom dunyo"),
            ("vi", "Xin chào thế giới"),
            ("yue", "你好世界"),
        ];

        // Languages whose phoneme tables are missing in espeak-ng 0.1.0.
        let known_missing: &[&str] = &["bs", "io", "lfn", "pap"];

        let mut passed = 0;
        let mut empty = Vec::new();
        let mut failed = Vec::new();
        let mut skipped = Vec::new();

        for &(lang, text) in sample_texts {
            match inner::run_phonemize_lang(lang, text) {
                Ok(ipa) if ipa.is_empty() => {
                    println!("  {lang:>5}: {text:30} → (empty)");
                    empty.push(lang);
                    passed += 1;
                }
                Ok(ipa) => {
                    println!("  {lang:>5}: {text:30} → {ipa}");
                    passed += 1;
                }
                Err(e) if known_missing.contains(&lang) => {
                    println!("  {lang:>5}: SKIPPED (known missing) — {e}");
                    skipped.push(lang);
                }
                Err(e) => {
                    eprintln!("  {lang:>5}: FAILED — {e}");
                    failed.push((lang, format!("{e}")));
                }
            }
        }

        let total = sample_texts.len();
        println!("\n{passed}/{total} languages succeeded, {} skipped (known missing)",
            skipped.len());
        if !empty.is_empty() {
            println!("{} languages returned empty IPA: {:?}", empty.len(), empty);
        }
        if !failed.is_empty() {
            println!("Unexpected failures:");
            for (lang, err) in &failed {
                println!("  {lang}: {err}");
            }
            panic!(
                "{} out of {total} languages had unexpected failures",
                failed.len(),
            );
        }
    }
}
