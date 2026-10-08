//! Integration tests for the text preprocessing pipeline.
//!
//! These tests verify the full `TextPreprocessor::process()` pipeline with
//! realistic TTS input strings — numbers, currencies, ordinals, units, etc.

use neutts::preprocess::TextPreprocessor;

fn pp() -> TextPreprocessor {
    TextPreprocessor::new()
}

// ── Numbers ───────────────────────────────────────────────────────────────────

#[test]
fn prep_integer_expanded() {
    let out = pp().process("There are 42 items.");
    assert!(out.contains("forty"), "got: {out}");
    assert!(out.contains("two"),   "got: {out}");
}

#[test]
fn prep_large_number() {
    let out = pp().process("The population is 8000000.");
    assert!(out.contains("million"), "got: {out}");
}

#[test]
fn prep_negative_number() {
    let out = pp().process("Temperature: -40 degrees.");
    assert!(out.contains("negative"), "got: {out}");
    assert!(out.contains("forty"),    "got: {out}");
}

// ── Ordinals ─────────────────────────────────────────────────────────────────

#[test]
fn prep_ordinals_expanded() {
    let out = pp().process("He came 1st, she came 2nd, I was 3rd.");
    assert!(out.contains("first"),  "got: {out}");
    assert!(out.contains("second"), "got: {out}");
    assert!(out.contains("third"),  "got: {out}");
}

#[test]
fn prep_ordinal_4th_to_20th() {
    let out = pp().process("4th 5th 10th 20th");
    assert!(out.contains("fourth"),   "got: {out}");
    assert!(out.contains("fifth"),    "got: {out}");
    assert!(out.contains("tenth"),    "got: {out}");
    assert!(out.contains("twentieth"),"got: {out}");
}

// ── Percentages ───────────────────────────────────────────────────────────────

#[test]
fn prep_percentage() {
    let out = pp().process("Accuracy was 99.5%.");
    assert!(out.contains("percent"),      "got: {out}");
    assert!(out.contains("ninety"),       "got: {out}");
    assert!(out.contains("point five") || out.contains("nine"), "got: {out}");
}

// ── Currency ──────────────────────────────────────────────────────────────────

#[test]
fn prep_currency_dollars_cents() {
    let out = pp().process("It costs $3.99.");
    assert!(out.contains("dollar"), "got: {out}");
    assert!(out.contains("cent"),   "got: {out}");
    assert!(out.contains("three"),  "got: {out}");
}

#[test]
fn prep_currency_billion() {
    let out = pp().process("The deal is worth $2.5B.");
    assert!(out.contains("billion"), "got: {out}");
    assert!(out.contains("dollar"), "got: {out}");
}

// ── Units ─────────────────────────────────────────────────────────────────────

#[test]
fn prep_unit_km() {
    let out = pp().process("Drive 5km to the next exit.");
    assert!(out.contains("kilometers"), "got: {out}");
    assert!(out.contains("five"),       "got: {out}");
}

#[test]
fn prep_unit_ghz() {
    let out = pp().process("CPU runs at 3.5GHz.");
    assert!(out.contains("gigahertz"), "got: {out}");
}

// ── Contractions ──────────────────────────────────────────────────────────────

#[test]
fn prep_cant_expanded() {
    let out = pp().process("I can't do that.");
    assert!(out.contains("cannot"), "got: {out}");
}

#[test]
fn prep_wont_expanded() {
    let out = pp().process("She won't come.");
    assert!(out.contains("will not"), "got: {out}");
}

#[test]
fn prep_dont_expanded() {
    let out = pp().process("They don't know.");
    assert!(out.contains("do not"), "got: {out}");
}

// ── Scientific notation ───────────────────────────────────────────────────────

#[test]
fn prep_scientific_notation() {
    let out = pp().process("Learning rate is 1e-4.");
    assert!(out.contains("times ten to the"), "got: {out}");
    assert!(out.contains("negative"),         "got: {out}");
}

// ── Time ──────────────────────────────────────────────────────────────────────

#[test]
fn prep_time_am() {
    let out = pp().process("The meeting is at 9:30 am.");
    assert!(out.contains("nine"), "got: {out}");
    assert!(out.contains("thirty") || out.contains("am"), "got: {out}");
}

// ── Scale suffixes ────────────────────────────────────────────────────────────

#[test]
fn prep_scale_k() {
    let out = pp().process("Salary is 120K.");
    assert!(out.contains("thousand"), "got: {out}");
}

#[test]
fn prep_scale_m() {
    let out = pp().process("Revenue hit 5M.");
    assert!(out.contains("million"), "got: {out}");
}

// ── Pipeline invariants ───────────────────────────────────────────────────────

#[test]
fn prep_output_is_lowercase() {
    let out = pp().process("Hello World GPT-4 NASA");
    assert!(
        out.chars().all(|c| c.is_lowercase() || c == ' '),
        "output should be all lowercase, got: {out}"
    );
}

#[test]
fn prep_no_leading_trailing_whitespace() {
    let out = pp().process("  hello world  ");
    assert!(!out.starts_with(' '), "got: '{out}'");
    assert!(!out.ends_with(' '),   "got: '{out}'");
}

#[test]
fn prep_no_double_spaces() {
    let out = pp().process("one    two     three");
    assert!(!out.contains("  "), "got: '{out}'");
}

#[test]
fn prep_html_removed() {
    let out = pp().process("<b>bold</b> and <em>italic</em>");
    assert!(!out.contains('<'), "got: {out}");
    assert!(!out.contains('>'), "got: {out}");
    assert!(out.contains("bold"), "got: {out}");
}

#[test]
fn prep_urls_removed() {
    let out = pp().process("Visit https://example.com for details.");
    assert!(!out.contains("http"), "got: {out}");
    assert!(!out.contains("example"), "got: {out}");
    assert!(out.contains("visit") || out.contains("for"), "got: {out}");
}

#[test]
fn prep_empty_string() {
    assert_eq!(pp().process(""), "");
}

#[test]
fn prep_whitespace_only() {
    assert_eq!(pp().process("   "), "");
}
