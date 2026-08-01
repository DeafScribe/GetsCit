#!/usr/bin/env python3
"""
generate-bell103.py

Synthesizes a period-accurate Bell 103 (300 baud) dial-and-connect
sequence from published frequency constants. Nothing here is sampled
from a recording, so there is no licensing question at all — the output
is yours outright.

Why synthesize rather than source a clip: Bell 103 has no handshake
negotiation to record. It is two frequency pairs and a carrier detect.
The elaborate screech people remember is V.34/V.90 (mid-1990s), which
post-dates Citadel-86 v3.49 by about five years and Bell 103 by thirty.
Using it would be the audio equivalent of putting a flat-screen monitor
in the CRT mockup.

Frequency constants (Bell 103 / ITU-T V.21 era, North America):
    Originating station:  mark 1270 Hz, space 1070 Hz
    Answering station:    mark 2225 Hz, space 2025 Hz
    Dial tone (precise):  350 Hz + 440 Hz
    Ringback:             440 Hz + 480 Hz
    DTMF: standard row/column pairs

Output is 8 kHz mono — genuinely correct rather than a compromise, since
the analog telephone network band-limited everything to roughly
300-3400 Hz anyway. It also keeps the file small enough to serve without
thinking about it.
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
    """Sum of sine waves. freqs may be a single float or an iterable."""
    if isinstance(freqs, (int, float)):
        freqs = [freqs]
    t = np.linspace(0, seconds, int(RATE * seconds), endpoint=False)
    sig = sum(np.sin(2 * np.pi * f * t) for f in freqs)
    return (sig / len(freqs)) * amp


def silence(seconds):
    return np.zeros(int(RATE * seconds))


def fsk(seconds, mark, space, baud=300, amp=0.28):
    """
    Pseudo-random FSK at the given baud rate — what actual data traffic
    sounds like once the carrier is up. Bits are random because we're
    imitating the texture of traffic, not encoding a real payload.
    """
    bit_len = 1.0 / baud
    n_bits = int(seconds / bit_len)
    rng = np.random.default_rng(1985)
    bits = rng.integers(0, 2, n_bits)

    out = []
    phase = 0.0
    for b in bits:
        f = mark if b else space
        n = int(RATE * bit_len)
        t = np.arange(n) / RATE
        seg = np.sin(2 * np.pi * f * t + phase)
        # Carry phase across bit boundaries — discontinuities would add
        # clicks that a real FSK modem doesn't produce.
        phase = (phase + 2 * np.pi * f * bit_len) % (2 * np.pi)
        out.append(seg)
    return np.concatenate(out) * amp if out else silence(seconds)


def line_noise(n, amp=0.006):
    rng = np.random.default_rng(103)
    return rng.normal(0, 1, n) * amp


def bandlimit(sig):
    """
    Crude one-pole smoothing to suggest telephone-line bandwidth rather
    than the clinically clean tones raw synthesis produces.
    """
    out = np.empty_like(sig)
    acc = 0.0
    a = 0.55
    for i, x in enumerate(sig):
        acc = a * x + (1 - a) * acc
        out[i] = acc
    return out


def envelope(sig, ramp=0.008):
    """Short fade in/out so segments don't click when concatenated."""
    n = int(RATE * ramp)
    if len(sig) < 2 * n:
        return sig
    e = np.ones(len(sig))
    e[:n] = np.linspace(0, 1, n)
    e[-n:] = np.linspace(1, 0, n)
    return sig * e


def build():
    parts = []

    # Off-hook, dial tone
    parts.append(envelope(tone([350, 440], 1.4, amp=0.22)))
    parts.append(silence(0.25))

    # Dial a 7-digit number
    for d in "5551990":
        parts.append(envelope(tone(DTMF[d], 0.09, amp=0.28), ramp=0.004))
        parts.append(silence(0.06))
    parts.append(silence(0.5))

    # Ringback: two rings, abbreviated. Real cadence is 2s on / 4s off;
    # the gap is shortened here because nobody wants to sit through it.
    for _ in range(2):
        parts.append(envelope(tone([440, 480], 1.1, amp=0.20)))
        parts.append(silence(0.9))

    # Answering modem asserts its mark tone (carrier).
    parts.append(envelope(tone(2225, 2.2, amp=0.30)))

    # Originating modem answers with its own mark. Both carriers now
    # present simultaneously — this overlap IS the "handshake" in Bell
    # 103. There is nothing more to it.
    both = tone(2225, 1.6, amp=0.22) + tone(1270, 1.6, amp=0.22)
    parts.append(envelope(both))

    # Traffic: full duplex, so both directions modulate at once.
    data = (fsk(2.6, 1270, 1070, amp=0.20)      # originating side
            + fsk(2.6, 2225, 2025, amp=0.18))   # answering side
    parts.append(envelope(data))

    sig = np.concatenate(parts)
    sig = bandlimit(sig)
    sig = sig + line_noise(len(sig))

    # Normalize with headroom
    peak = np.max(np.abs(sig))
    if peak > 0:
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
    write_wav(sig, 'bell103-connect.wav')
    print(f"wrote bell103-connect.wav  ({len(sig)/RATE:.1f}s, {RATE} Hz mono)")
