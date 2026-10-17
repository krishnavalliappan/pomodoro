#!/usr/bin/env python3
"""Generate the app's built-in sounds as 44.1 kHz 16-bit mono WAV files.

Stdlib only, and deterministic: no wall-clock, no unseeded randomness, so re-running
produces byte-identical files. Output goes to App/Resources/Sounds/.

    python3 scripts/gen_sounds.py
"""

import math
import os
import struct
import wave

RATE = 44100
OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Resources", "Sounds")

# Ratios of a struck bell's inharmonic modes (hum, prime, tierce, quint, nominal, upper),
# loosely after a tuned church bell. Amplitudes fall off and higher modes die faster,
# which keeps the timbre warm instead of tinny.
BELL_PARTIALS = [
    # (ratio, amplitude, decay time constant relative to the note's base decay)
    (0.50, 0.18, 1.30),
    (1.00, 1.00, 1.00),
    (1.19, 0.22, 0.75),
    (1.50, 0.16, 0.60),
    (2.00, 0.30, 0.50),
    (2.74, 0.08, 0.30),
    (4.07, 0.03, 0.18),
]

# Circular-plate modes of a singing bowl are strongly inharmonic.
BOWL_PARTIALS = [
    (1.00, 1.00, 1.00),
    (2.71, 0.45, 0.70),
    (5.15, 0.16, 0.45),
    (8.17, 0.05, 0.30),
]


def db_to_gain(db):
    return 10.0 ** (db / 20.0)


def silence(seconds):
    return [0.0] * int(round(seconds * RATE))


def mix_into(buf, start_s, samples):
    offset = int(round(start_s * RATE))
    for i, s in enumerate(samples):
        j = offset + i
        if j >= len(buf):
            break
        buf[j] += s


def attack_env(t, attack):
    """Raised-cosine attack: zero slope at both ends, so no click on onset."""
    if t >= attack:
        return 1.0
    return 0.5 - 0.5 * math.cos(math.pi * t / attack)


def bell_note(freq, length, decay, attack=0.006, partials=BELL_PARTIALS, beat_hz=0.0):
    out = []
    n = int(round(length * RATE))
    for i in range(n):
        t = i / RATE
        s = 0.0
        for ratio, amp, rel in partials:
            f = freq * ratio
            if f >= RATE * 0.45:
                continue
            env = math.exp(-t / (decay * rel))
            v = math.sin(2.0 * math.pi * f * t)
            if beat_hz:
                # A detuned twin per mode gives the slow shimmer of a real bowl.
                v = 0.5 * (v + math.sin(2.0 * math.pi * (f + beat_hz * ratio) * t + 0.7))
            s += amp * env * v
        out.append(s * attack_env(t, attack))
    return out


def fade_edges(buf, fade_in=0.002, fade_out=0.08):
    n = len(buf)
    fi = max(1, int(fade_in * RATE))
    fo = max(1, int(fade_out * RATE))
    for i in range(min(fi, n)):
        buf[i] *= 0.5 - 0.5 * math.cos(math.pi * i / fi)
    for k in range(min(fo, n)):
        i = n - 1 - k
        buf[i] *= 0.5 - 0.5 * math.cos(math.pi * k / fo)
    buf[0] = 0.0
    buf[-1] = 0.0
    return buf


def windowed_rms_db(buf, window=0.4):
    """Loudest 400 ms RMS, a rough stand-in for momentary loudness (no K-weighting)."""
    w = max(1, min(len(buf), int(window * RATE)))
    hop = max(1, w // 4)
    best = 0.0
    for start in range(0, max(1, len(buf) - w + 1), hop):
        seg = buf[start:start + w]
        best = max(best, sum(x * x for x in seg) / len(seg))
    return 10.0 * math.log10(best) if best > 0 else -120.0


def normalize(buf, loudness_db, peak_db=-3.0):
    """Aim for a target loudness but never let the peak exceed `peak_db`."""
    peak = max(abs(x) for x in buf)
    rms_gain = db_to_gain(loudness_db - windowed_rms_db(buf))
    peak_gain = db_to_gain(peak_db) / peak
    g = min(rms_gain, peak_gain)
    return [x * g for x in buf]


def chime_focus_end():
    # Warm rising C major arpeggio: C5, E5, G5.
    buf = silence(1.35)
    for k, freq in enumerate((523.25, 659.26, 783.99)):
        mix_into(buf, 0.16 * k, bell_note(freq, 1.35 - 0.16 * k, decay=0.42, attack=0.008))
    return normalize(fade_edges(buf, fade_out=0.25), loudness_db=-14.0)


def chime_break_end():
    # Brighter rising fifth an octave up: A5, E6.
    buf = silence(1.0)
    for k, freq in enumerate((880.00, 1318.51)):
        mix_into(buf, 0.14 * k, bell_note(freq, 1.0 - 0.14 * k, decay=0.30, attack=0.004))
    return normalize(fade_edges(buf, fade_out=0.2), loudness_db=-14.0)


def start():
    # Soft "pop": a sine gliding 720 -> 360 Hz with a quick bloom and decay.
    n = int(0.14 * RATE)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = 360.0 + 360.0 * math.exp(-t / 0.018)
        phase += 2.0 * math.pi * f / RATE
        env = attack_env(t, 0.004) * math.exp(-t / 0.035)
        out.append(env * (math.sin(phase) + 0.15 * math.sin(2.0 * phase)))
    return normalize(fade_edges(out, fade_in=0.001, fade_out=0.03), loudness_db=-18.0, peak_db=-6.0)


def tick():
    # Woodblock: two strongly damped body modes plus a tiny deterministic noise transient.
    n = int(0.035 * RATE)
    out = []
    seed = 0x2545F491
    for i in range(n):
        t = i / RATE
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        noise = (seed / 0x3FFFFFFF - 1.0) * math.exp(-t / 0.0015)
        body = (math.sin(2.0 * math.pi * 1750.0 * t) * math.exp(-t / 0.006)
                + 0.5 * math.sin(2.0 * math.pi * 2930.0 * t) * math.exp(-t / 0.004))
        out.append(attack_env(t, 0.0008) * (body + 0.25 * noise))
    # Deliberately quiet: it repeats every second during focus.
    return normalize(fade_edges(out, fade_in=0.0005, fade_out=0.012), loudness_db=-30.0, peak_db=-15.0)


def bowl():
    buf = bell_note(196.00, 3.0, decay=1.25, attack=0.06, partials=BOWL_PARTIALS, beat_hz=0.9)
    return normalize(fade_edges(buf, fade_out=0.6), loudness_db=-14.0)


SOUNDS = {
    "chime_focus_end": chime_focus_end,
    "chime_break_end": chime_break_end,
    "start": start,
    "tick": tick,
    "bowl": bowl,
}


def write_wav(path, samples):
    frames = b"".join(
        struct.pack("<h", max(-32768, min(32767, int(round(s * 32767.0))))) for s in samples
    )
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, make in SOUNDS.items():
        samples = make()
        path = os.path.join(OUT_DIR, name + ".wav")
        write_wav(path, samples)
        peak = max(abs(x) for x in samples)
        print(f"{name}.wav  {len(samples) / RATE:.3f}s  {os.path.getsize(path)} B  "
              f"peak {20 * math.log10(peak):.1f} dBFS  rms400 {windowed_rms_db(samples):.1f} dB")


if __name__ == "__main__":
    main()
