// Throwaway probe: what IPA does the phonemizer produce for decimal text?
use neutts::phonemize::phonemize;

fn main() {
    let cases = [
        "the ratio is 3.14 today",
        "the ratio is three point one four today",
        "costs hit 1,000 coins",
    ];
    for c in cases {
        println!("{c:?} -> {:?}", phonemize(c, "en-us"));
    }
    let _ = main;
}

#[test]
fn probe() {
    main();
}
