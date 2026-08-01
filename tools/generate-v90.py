#!/usr/bin/env python3
"""
generate-v90.py

Synthesizes the familiar V.34/V.90 dial-up connect sequence — the one
people actually remember.

HONESTY ABOUT WHAT THIS IS: an imitation of each handshake phase's
audible texture, not a spec-accurate implementation. Bell 103 could be
generated exactly because it genuinely is two tones. V.34 is a
multi-phase negotiation (V.8 capability exchange, line probing, several
training rounds, trellis-coded QAM) and a faithful implementation would
be a modem, not a sound file. Frequencies below are taken from the real
specifications where they're simple constants; the phases that carry
actual encoded data are approximated by signals with the right spectral
shape. It sounds correct. It would not decode.

Nothing is sampled from a recording, so there's no licensing question.

Phases, in order, with what each one sounds like:

  1. Dial tone            350 + 440 Hz
  2. DTMF dialing         standard row/column pairs
  3. Ringback             440 + 480 Hz
  4. ANSam                2100 Hz, amplitude-modulated at 15 Hz, with
                          phase reversals every 450 ms. The long "beeeep"
                          that starts the whole thing. The AM is why it
                          warbles rather than sitting still.
  5. V.8 CM/JM exchange   300 baud FSK. Calling modem uses V.21 channel 1
                          (980/1180 Hz), answering uses channel 2
                          (1650/1850 Hz). This is the "boodly-boodly"
                          burst where the two ends agree on what they are.
  6. Line probing         21 tones spaced 150 Hz apart. Sent twice (L1
                          then L2, at different power). The "whoosh" —
                          each end measuring the line's frequency
                          response to decide which carrier and rate to
                          use.
  7. Training             Sweeps plus scrambled-sequence noise, in two
                          rounds. The scratchy rising/falling section.
  8. Data mode            Band-limited noise. Scrambled QAM genuinely
                          does sound like this — the "shhhhhh" that means
                          you're connected.

Output is 8 kHz mono, matching telephone bandwidth.
"""

import numpy as np
import wave
import struct

RATE = 8000

DTMF = {
    '1': (697, 1209), '2': (697, 1336), '3': (697, 1477),
    '4': (770, 1209), '5': (770, 1336), '6': (770, 1477),
    '7': (852, 1209), '8': (852, 1336), '9': (852, 1477),
    '*': (941, 1209), '0': (941, 1336), '#': (941, 1477),
}


def tone(freqs, seconds, amp=0.3):
    if isinstance(freqs, (int, float)):
        freqs = [freqs]
    t = np.linspace(0, seconds, int(RATE * seconds), endpoint=False)
    sig = sum(np.sin(2 * np.pi * f * t) for f in freqs)
    return (sig / len(freqs)) * amp


def silence(seconds):
    return np.zeros(int(RATE * seconds))


def envelope(sig, ramp=0.008):
    n = int(RATE * ramp)
    if len(sig) < 2 * n:
        return sig
    e = np.ones(len(sig))
    e[:n] = np.linspace(0, 1, n)
    e[-n:] = np.linspace(1, 0, n)
    return sig * e


def bandpass(sig, lo=300, hi=3400):
    """FFT-domain brickwall. Crude, but this is telephone bandwidth, and
    the goal is spectral shape rather than filter elegance."""
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(len(sig), 1 / RATE)
    spec[(freqs < lo) | (freqs > hi)] = 0
    return np.fft.irfft(spec, n=len(sig))


def ansam(seconds, amp=0.32):
    """
    2100 Hz answer tone with 15 Hz amplitude modulation and a phase
    reversal every 450 ms. The AM is what makes it warble; the phase
    reversals are the modem's way of saying "echo cancellation
    permitted" and are audible as a faint click.
    """
    t = np.linspace(0, seconds, int(RATE * seconds), endpoint=False)
    phase = np.zeros_like(t)
    reversal = 0.450
    for k in range(1, int(seconds / reversal) + 1):
        phase[t >= k * reversal] += np.pi
    am = 1.0 + 0.20 * np.sin(2 * np.pi * 15 * t)
    return np.sin(2 * np.pi * 2100 * t + phase) * am * amp


def fsk(seconds, mark, space, baud=300, amp=0.26, seed=1994):
    """Phase-continuous FSK. Random bits — texture, not payload."""
    bit_len = 1.0 / baud
    n_bits = max(1, int(seconds / bit_len))
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, n_bits)
    out, phase = [], 0.0
    for b in bits:
        f = mark if b else space
        n = int(RATE * bit_len)
        t = np.arange(n) / RATE
        out.append(np.sin(2 * np.pi * f * t + phase))
        phase = (phase + 2 * np.pi * f * bit_len) % (2 * np.pi)
    return np.concatenate(out) * amp


def line_probe(seconds, amp=0.30, tilt=1.0):
    """
    V.34 Phase 2 probing signal: 21 tones at 150 Hz spacing. Real L1/L2
    differ in power level, which `tilt` stands in for. Phases are
    randomized so the tones don't all align into a click train.
    """
    t = np.linspace(0, seconds, int(RATE * seconds), endpoint=False)
    rng = np.random.default_rng(34)
    sig = np.zeros_like(t)
    for k in range(1, 22):
        f = 150 * k
        if f > 3600:
            break
        sig += np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    return sig / 21 * amp * tilt


def chirp(seconds, f0, f1, amp=0.25):
    t = np.linspace(0, seconds, int(RATE * seconds), endpoint=False)
    k = (f1 - f0) / seconds
    return np.sin(2 * np.pi * (f0 * t + 0.5 * k * t * t)) * amp


def training(seconds, seed=90, amp=0.30):
    """
    Approximates the TRN/scrambled-sequence rounds: shaped noise with
    some tonal structure poking through, which is what makes this
    section sound scratchy rather than smooth.
    """
    n = int(RATE * seconds)
    rng = np.random.default_rng(seed)
    noise = bandpass(rng.normal(0, 1, n), 400, 3300)
    noise = noise / (np.max(np.abs(noise)) or 1)
    t = np.arange(n) / RATE
    tonal = 0.35 * np.sin(2 * np.pi * 1800 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 7 * t))
    return (0.75 * noise + tonal) * amp


def data_mode(seconds, amp=0.26, seed=56):
    """Scrambled QAM. Band-limited noise is not an approximation here —
    it's genuinely what a modulated data carrier sounds like."""
    n = int(RATE * seconds)
    rng = np.random.default_rng(seed)
    sig = bandpass(rng.normal(0, 1, n), 300, 3400)
    return sig / (np.max(np.abs(sig)) or 1) * amp


def line_noise(n, amp=0.005):
    return np.random.default_rng(7).normal(0, 1, n) * amp


def build():
    p = []

    # 1-3: dial, DTMF, ringback
    p.append(envelope(tone([350, 440], 1.2, amp=0.22)))
    p.append(silence(0.22))
    for d in "5551995":
        p.append(envelope(tone(DTMF[d], 0.085, amp=0.28), ramp=0.004))
        p.append(silence(0.055))
    p.append(silence(0.45))
    for _ in range(2):
        p.append(envelope(tone([440, 480], 1.1, amp=0.20)))
        p.append(silence(0.85))

    # 4: ANSam — the long opening beep
    p.append(envelope(ansam(3.1)))
    p.append(silence(0.12))

    # 5: V.8 capability exchange, alternating directions
    p.append(envelope(fsk(0.55, 980, 1180, seed=1)))        # CM, calling
    p.append(silence(0.05))
    p.append(envelope(fsk(0.50, 1650, 1850, seed=2)))       # JM, answering
    p.append(silence(0.05))
    p.append(envelope(fsk(0.35, 980, 1180, seed=3)))        # CM again
    p.append(silence(0.15))

    # 6: line probing, twice at different levels
    p.append(envelope(line_probe(0.85, tilt=0.7)))          # L1
    p.append(silence(0.10))
    p.append(envelope(line_probe(0.85, tilt=1.0)))          # L2
    p.append(silence(0.12))

    # 7: training rounds — sweeps interleaved with scrambled sequences
    p.append(envelope(chirp(0.45, 600, 3300)))
    p.append(envelope(training(1.5, seed=11)))
    p.append(envelope(chirp(0.35, 3300, 700)))
    p.append(envelope(training(1.9, seed=12)))
    p.append(silence(0.08))
    p.append(envelope(training(1.2, seed=13, amp=0.34)))

    # 8: connected
    p.append(envelope(data_mode(3.4), ramp=0.05))

    sig = np.concatenate(p)
    sig = sig + line_noise(len(sig))
    peak = np.max(np.abs(sig))
    if peak:
        sig = sig / peak * 0.85
    return sig


def write_wav(sig, path):
    data = (sig * 32767).astype(np.int16)
    with wave.open(path, 'w') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack('<%dh' % len(data), *data))


if __name__ == '__main__':
    sig = build()
    write_wav(sig, 'v90-connect.wav')
    print(f"wrote v90-connect.wav  ({len(sig)/RATE:.1f}s, {RATE} Hz mono)")
