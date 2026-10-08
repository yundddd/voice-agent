//! Integration tests for the speech-token encoder/decoder helpers.
//!
//! These tests exercise the round-trip between integer token IDs and their
//! text representation, and verify the prompt builder output.

use neutts::tokens::{build_prompt, extract_ids, ids_to_token_str, STOP_TOKEN};

// ── Round-trip ────────────────────────────────────────────────────────────────

#[test]
fn tokens_roundtrip_empty() {
    let ids: &[i32] = &[];
    let s = ids_to_token_str(ids);
    assert_eq!(s, "");
    assert_eq!(extract_ids(&s), ids);
}

#[test]
fn tokens_roundtrip_single() {
    let ids = vec![42i32];
    let s = ids_to_token_str(&ids);
    assert_eq!(s, "<|speech_42|>");
    assert_eq!(extract_ids(&s), ids);
}

#[test]
fn tokens_roundtrip_all_vocab() {
    // The model uses IDs 0..1023. Verify the full vocabulary round-trips.
    let ids: Vec<i32> = (0..1024).collect();
    let s = ids_to_token_str(&ids);
    let back = extract_ids(&s);
    assert_eq!(back, ids, "full vocabulary round-trip failed");
}

#[test]
fn tokens_roundtrip_large_codes() {
    // Codes can exceed 1023 (FSQ range 0..65535). Check boundary values.
    let ids = vec![0i32, 1023, 1024, 32768, 65535];
    let s = ids_to_token_str(&ids);
    assert_eq!(extract_ids(&s), ids);
}

// ── Encoding format ───────────────────────────────────────────────────────────

#[test]
fn tokens_format_is_speech_n() {
    let s = ids_to_token_str(&[7]);
    assert_eq!(s, "<|speech_7|>");
}

#[test]
fn tokens_no_delimiter_between_tokens() {
    // The model prompt uses contiguous tokens with no space between them.
    let s = ids_to_token_str(&[1, 2, 3]);
    assert_eq!(s, "<|speech_1|><|speech_2|><|speech_3|>");
    assert!(!s.contains(' '), "tokens should be adjacent with no space");
}

// ── Extraction ────────────────────────────────────────────────────────────────

#[test]
fn tokens_extract_ignores_non_speech_tags() {
    let s = "<|SPEECH_GENERATION_START|><|speech_10|><|speech_20|><|SPEECH_GENERATION_END|>";
    assert_eq!(extract_ids(s), vec![10, 20]);
}

#[test]
fn tokens_extract_mixed_content() {
    let s = "some text <|speech_5|> more text <|speech_100|> end";
    assert_eq!(extract_ids(s), vec![5, 100]);
}

#[test]
fn tokens_extract_empty_string() {
    assert!(extract_ids("").is_empty());
}

#[test]
fn tokens_extract_no_tags() {
    assert!(extract_ids("hello world").is_empty());
}

#[test]
fn tokens_stop_token_does_not_leak_into_ids() {
    let s = format!("<|speech_1|>{STOP_TOKEN}<|speech_2|>");
    // STOP_TOKEN must not parse as a speech ID.
    assert_eq!(extract_ids(&s), vec![1, 2]);
}

// ── Prompt builder ────────────────────────────────────────────────────────────

#[test]
fn prompt_contains_all_structural_markers() {
    let prompt = build_prompt("hɛˈloʊ", "wɜːld", &[0, 1, 2]);
    assert!(prompt.contains("user:"),                    "missing 'user:' prefix");
    assert!(prompt.contains("<|TEXT_PROMPT_START|>"),    "missing text-start tag");
    assert!(prompt.contains("<|TEXT_PROMPT_END|>"),      "missing text-end tag");
    assert!(prompt.contains("assistant:"),               "missing 'assistant:' prefix");
    assert!(prompt.contains("<|SPEECH_GENERATION_START|>"), "missing speech-start tag");
}

#[test]
fn prompt_contains_both_ipa_strings() {
    let prompt = build_prompt("ref ipa", "input ipa", &[]);
    // Both IPA strings appear together in the text region.
    assert!(prompt.contains("ref ipa input ipa"), "IPA strings not found: {prompt}");
}

#[test]
fn prompt_contains_ref_codes_as_tokens() {
    let ref_codes = vec![5i32, 100, 999];
    let prompt = build_prompt("", "", &ref_codes);
    assert!(prompt.contains("<|speech_5|>"),   "missing code 5");
    assert!(prompt.contains("<|speech_100|>"), "missing code 100");
    assert!(prompt.contains("<|speech_999|>"), "missing code 999");
}

#[test]
fn prompt_ref_codes_appear_after_speech_start() {
    let prompt = build_prompt("a", "b", &[7, 8]);
    let start_pos = prompt.find("<|SPEECH_GENERATION_START|>").unwrap();
    let token_pos = prompt.find("<|speech_7|>").unwrap();
    assert!(
        token_pos > start_pos,
        "ref codes should appear after SPEECH_GENERATION_START"
    );
}

#[test]
fn prompt_text_region_before_codes() {
    // The text prompt must appear before the speech tokens.
    let prompt = build_prompt("ref", "inp", &[42]);
    let text_end  = prompt.find("<|TEXT_PROMPT_END|>").unwrap();
    let code_pos  = prompt.find("<|speech_42|>").unwrap();
    assert!(
        code_pos > text_end,
        "speech tokens must appear after TEXT_PROMPT_END"
    );
}
