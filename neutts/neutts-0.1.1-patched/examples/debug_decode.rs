/// Quick numerical debugging tool — decode a fixed code sequence and print
/// per-token RMS so it can be compared against the numpy reference.
///
/// Usage: cargo run --example debug_decode
fn main() -> anyhow::Result<()> {
    // Same 20 identical codes used in the numpy test
    let codes: Vec<i32> = vec![1000; 20];

    let dec = neutts::NeuCodecDecoder::new()?;
    let audio = dec.decode(&codes)?;

    let hop = 480usize;
    let n_tokens = codes.len();

    println!("Per-token RMS (Rust):");
    for i in 0..n_tokens {
        let start = i * hop;
        let end   = (start + hop).min(audio.len());
        let rms: f32 = {
            let s = &audio[start..end];
            (s.iter().map(|&x| x * x).sum::<f32>() / s.len() as f32).sqrt()
        };
        println!("  token {:2}: rms={:.4}", i, rms);
    }

    let peak: f32 = audio.iter().cloned().fold(0.0_f32, f32::max);
    let rms_all: f32 = (audio.iter().map(|&x| x * x).sum::<f32>() / audio.len() as f32).sqrt();
    println!("Overall: peak={:.4}  rms={:.4}  samples={}", peak, rms_all, audio.len());

    Ok(())
}
