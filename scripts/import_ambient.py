#!/usr/bin/env python3
"""Build the ambient sound library in App/Resources/Ambient/.

Recorded sounds come from Blanket (github.com/rafaelmardojai/blanket), pinned to one commit and
verified by sha256. Only CC0, Public Domain and CC BY files are taken: Blanket's white and pink
noise are CC BY-SA, so white, pink and brown noise are generated here instead (seeded, stdlib).

Every sound is trimmed, loudness-normalised (EBU R128, two-pass linear), given a crossfaded loop
seam so the end runs straight into the start, and encoded as AAC (.m4a, 96 kbps). The script also
writes ambient-credits.json, which the app reads as its manifest and its credits list, and
SOUNDS_LICENSING.md at the repo root, which mirrors it.

Needs ffmpeg with the native AAC encoder and the loudnorm filter. It looks, in order, at
--ffmpeg, $FFMPEG, the imageio-ffmpeg package (a pip-installable static build), and PATH.

    python3 scripts/import_ambient.py [--ffmpeg PATH] [--cache DIR]

Re-running with the same ffmpeg build produces the same files.
"""

import argparse
import array
import hashlib
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT_DIR = os.path.join(ROOT, "App", "Resources", "Ambient")
MANIFEST = os.path.join(OUT_DIR, "ambient-credits.json")
LICENSING = os.path.join(ROOT, "SOUNDS_LICENSING.md")

BLANKET_REPO = "https://github.com/rafaelmardojai/blanket"
BLANKET_COMMIT = "775f2a767230a9681850d1b1e085be58656f1382"
BLANKET_RAW = f"https://raw.githubusercontent.com/rafaelmardojai/blanket/{BLANKET_COMMIT}/data/resources/sounds/"

RATE = 44100
CHANNELS = 2
BITRATE = "96k"
# AAC codes 1024-frame packets; a loop that fills whole packets leaves no padding to trim.
PACKET = 1024
# Quiet enough that three layers summed stay well clear of clipping.
LOUDNESS = {"I": -24.0, "TP": -3.0, "LRA": 11.0}
MAX_SECONDS = 120.0
NOISE_SECONDS = 30.0
BUDGET_BYTES = 12 * 1024 * 1024

LICENSES = {
    "CC0-1.0": ("CC0 1.0", "https://creativecommons.org/publicdomain/zero/1.0/"),
    "PD": ("Public Domain", None),
    "CC-BY-3.0": ("CC BY 3.0", "https://creativecommons.org/licenses/by/3.0/"),
    "CC-BY-4.0": ("CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/"),
    "original": ("Original (generated)", None),
}
ALLOWED_SOURCE_LICENSES = {"CC0-1.0", "PD", "CC-BY-3.0", "CC-BY-4.0"}

# Licenses are as stated on each original page (checked 2026-10-17); Blanket's table gives the
# same family, without versions for CC BY. "editedBy" is Blanket's editor, per its table.
RECORDED = [
    dict(id="forest", title="Forest", symbol="tree", file="birds.ogg",
         sha256="e59b19c2a377d5835d07e7ec8f8c876b9f40ae7f703738b55d616ef96a1638b2",
         work="WoodThrushinMorningShawneeForestMay272012.wav", author="kvgarlic",
         url="https://freesound.org/people/kvgarlic/sounds/156826/", license="CC0-1.0", editedBy="Porrumentzio"),
    dict(id="rain", title="Rain", symbol="cloud.rain", file="rain.ogg",
         sha256="b84c1daf259a24283be40b7663656d17676df4eb60c1e0332820570db891848a",
         work="rain ambience", author="alex36917",
         url="https://freesound.org/people/alex36917/sounds/524605/", license="CC-BY-4.0", editedBy="Porrumentzio"),
    dict(id="storm", title="Storm", symbol="cloud.bolt.rain", file="storm.ogg",
         sha256="7e2a9bee62273b1deb169b6f7a308b70ead6ae450d3f6c75b854a44e4bef7b5a",
         work="Infinite Storm.wav", author="digifishmusic",
         url="https://freesound.org/people/digifishmusic/sounds/41739/", license="CC-BY-4.0", editedBy="Porrumentzio"),
    dict(id="wind", title="Wind", symbol="wind", file="wind.ogg",
         sha256="cfdc81be69cd5f434ebfeb708bdf094725f3052d76691f550ff0e10eee3e32d2",
         work="Wind blowing in a field in Texas, USA", author="felix.blume",
         url="https://freesound.org/people/felix.blume/sounds/217506/", license="CC0-1.0", editedBy="Porrumentzio"),
    dict(id="waves", title="Waves", symbol="water.waves", file="waves.ogg",
         sha256="20e1aec7c7542f71645275871650881ea33bc92bd9816b243ea920bb1daa51a0",
         work="oceanwavescrushing.wav", author="Luftrum",
         url="https://freesound.org/people/Luftrum/sounds/48412/", license="CC-BY-4.0", editedBy="Porrumentzio"),
    dict(id="stream", title="Stream", symbol="drop", file="stream.ogg",
         sha256="ce372c5db561168636647dd7d4aac39ef1785ae5d415ad0e589186ce1b7c5796",
         work="stream2.wav", author="gluckose",
         url="https://freesound.org/people/gluckose/sounds/333987/", license="CC0-1.0", editedBy=None),
    dict(id="night", title="Night", symbol="moon.stars", file="summer-night.ogg",
         sha256="2eb2efb8f5c6733e74dc8546f2ecfac40407e8242a9eed96a72e0fc68790ac6f",
         work="Crickets Chirping At Night", author="Lisa Redfern",
         url="https://soundbible.com/2083-Crickets-Chirping-At-Night.html", license="PD", editedBy=None),
    dict(id="fireplace", title="Fireplace", symbol="flame", file="fireplace.ogg",
         sha256="a6395379a32c2dc30dd870c4571ded4a5311435aacfe354b3a82a9b3ab98620b",
         work="Fireplace", author="ezwa",
         url="https://soundbible.com/1543-Fireplace.html", license="PD", editedBy=None),
    dict(id="cafe", title="Café", symbol="cup.and.saucer", file="coffee-shop.ogg",
         sha256="397b5d95f06df69ba2989147cf9c37a417b2dc5950c1a16fbe6be6fa372d25ef",
         work="Restaurant Ambiance", author="stephan",
         url="https://soundbible.com/1664-Restaurant-Ambiance.html", license="PD", editedBy=None),
    dict(id="city", title="City", symbol="building.2", file="city.ogg",
         sha256="3e9a574a0d93f75872e0f37304c622e6cb76b28714deb1a50af666293105ae75",
         work="NYC_street leve02l.wav", author="gezortenplotz",
         url="https://freesound.org/people/gezortenplotz/sounds/44796/", license="CC-BY-3.0", editedBy="Porrumentzio"),
    dict(id="train", title="Train", symbol="tram", file="train.ogg",
         sha256="b749ecf8f04842075c061e2f5572c85b2827d9ecc0670476f3339a9288bb4d71",
         work="Trains of the Yamanote Line", author="SDLx",
         url="https://freesound.org/people/SDLx/sounds/259988/", license="CC-BY-3.0", editedBy=None),
    dict(id="boat", title="Boat", symbol="sailboat", file="boat.ogg",
         sha256="e6f3565750e2d3dd0dcb5bd3f826c10e302df4d1d044dd177af0707abe027dea",
         work="Ambience_Sea_Boat_Night_Ropes_4.wav", author="Falcet",
         url="https://freesound.org/people/Falcet/sounds/439365/", license="CC0-1.0", editedBy="Porrumentzio"),
]

NOISES = [
    dict(id="white-noise", title="White Noise", symbol="waveform", color="white", seed=0x57A1),
    dict(id="pink-noise", title="Pink Noise", symbol="waveform.path", color="pink", seed=0x9175),
    dict(id="brown-noise", title="Brown Noise", symbol="waveform.path.ecg", color="brown", seed=0xB205),
]

# Longer for recordings so a swell doesn't cut off; noise has nothing to line up.
SEAM_SECONDS = {"recorded": 3.0, "noise": 1.0}


def find_ffmpeg(explicit):
    for candidate in (explicit, os.environ.get("FFMPEG")):
        if candidate:
            return candidate
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        pass
    found = shutil.which("ffmpeg")
    if not found:
        sys.exit("ffmpeg not found: pass --ffmpeg, set $FFMPEG, or `pip install imageio-ffmpeg`")
    return found


def ffmpeg_version(ffmpeg):
    out = subprocess.run([ffmpeg, "-hide_banner", "-version"], capture_output=True, text=True, check=True).stdout
    return out.splitlines()[0]


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(sound, cache):
    """Downloads into the cache unless a verified copy is already there."""
    path = os.path.join(cache, sound["file"])
    if not (os.path.exists(path) and sha256_of(path) == sound["sha256"]):
        url = BLANKET_RAW + sound["file"]
        print(f"  downloading {url}")
        with urllib.request.urlopen(url, timeout=60) as response, open(path + ".part", "wb") as f:
            shutil.copyfileobj(response, f)
        os.replace(path + ".part", path)
    actual = sha256_of(path)
    if actual != sound["sha256"]:
        sys.exit(f"sha256 mismatch for {sound['file']}: expected {sound['sha256']}, got {actual}")
    return path


def run(cmd, stdin=None):
    result = subprocess.run(cmd, input=stdin, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr.decode(errors="replace"))
        sys.exit(f"command failed: {' '.join(cmd[:4])} …")
    return result


RAW_IN = ["-f", "f32le", "-ar", str(RATE), "-ac", str(CHANNELS)]


def normalised_pcm(ffmpeg, input_args, frames, prefilter=""):
    """Two-pass loudnorm in linear mode, so the gain is constant and the seam stays matched."""
    trim = f"{prefilter}atrim=end_sample={frames},"
    target = ":".join(f"{k}={v}" for k, v in LOUDNESS.items())
    measure = run([ffmpeg, "-hide_banner", "-nostdin", *input_args, "-af",
                   f"aresample={RATE},{trim}loudnorm={target}:print_format=json", "-f", "null", "-"])
    stats = json.loads(re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", measure.stderr.decode()).group(0))
    second = (f"loudnorm={target}:linear=true:measured_I={stats['input_i']}:measured_TP={stats['input_tp']}"
              f":measured_LRA={stats['input_lra']}:measured_thresh={stats['input_thresh']}"
              f":offset={stats['target_offset']}")
    # loudnorm works at 192 kHz internally, hence the second resample.
    pcm = run([ffmpeg, "-hide_banner", "-nostdin", *input_args, "-af",
               f"aresample={RATE},{trim}{second},aresample={RATE}", "-ac", str(CHANNELS),
               "-f", "f32le", "-acodec", "pcm_f32le", "-"]).stdout
    samples = array.array("f")
    samples.frombytes(pcm)
    return samples, float(stats["input_i"])


def loop_frames(available, seam):
    """The longest loop at most MAX_SECONDS whose length after the seam fills whole AAC packets."""
    usable = min(available, int(MAX_SECONDS * RATE) + seam)
    loop = ((usable - seam) // PACKET) * PACKET
    return loop + seam, loop


def crossfade_seam(samples, seam):
    """Folds the last `seam` frames over the first with an equal-power fade.

    The result ends on the frame just before the folded tail began, which is what follows its
    first frame in the recording, so looping it has no seam. Equal power suits uncorrelated
    ambience: the level doesn't dip mid-fade.
    """
    total = len(samples) // CHANNELS
    loop = total - seam
    out = samples[: loop * CHANNELS]
    tail = loop * CHANNELS
    for i in range(seam):
        t = (i + 0.5) / seam * (math.pi / 2)
        fade_in, fade_out = math.sin(t), math.cos(t)
        for c in range(CHANNELS):
            j = i * CHANNELS + c
            out[j] = samples[j] * fade_in + samples[tail + j] * fade_out
    return out


def encode(ffmpeg, samples, path):
    run([ffmpeg, "-hide_banner", "-nostdin", "-y", *RAW_IN, "-i", "-", "-c:a", "aac", "-b:a", BITRATE,
         "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", "-movflags", "+faststart",
         path], stdin=samples.tobytes())


def decoded_frames(ffmpeg, path):
    pcm = run([ffmpeg, "-hide_banner", "-nostdin", "-i", path, "-f", "f32le", "-acodec", "pcm_f32le", "-"]).stdout
    return len(pcm) // (4 * CHANNELS)


def probe_frames(ffmpeg, path):
    """Frames ffmpeg decodes from `path` at RATE, which bounds how much there is to loop."""
    pcm = run([ffmpeg, "-hide_banner", "-nostdin", "-i", path, "-af", f"aresample={RATE}",
               "-ac", str(CHANNELS), "-f", "f32le", "-acodec", "pcm_f32le", "-"]).stdout
    return len(pcm) // (4 * CHANNELS)


def noise(color, seed, frames):
    """Gaussian white noise, independent per channel, shaped for pink and brown."""
    rng = random.Random(seed)
    out = array.array("f", bytes(4 * frames * CHANNELS))
    for c in range(CHANNELS):
        b0 = b1 = b2 = b3 = b4 = b5 = b6 = 0.0
        brown = 0.0
        for i in range(frames):
            white = rng.gauss(0.0, 0.25)
            if color == "white":
                value = white
            elif color == "pink":
                # Paul Kellet's refined filter: -3 dB/octave within 0.05 dB above 9 Hz.
                b0 = 0.99886 * b0 + white * 0.0555179
                b1 = 0.99332 * b1 + white * 0.0750759
                b2 = 0.96900 * b2 + white * 0.1538520
                b3 = 0.86650 * b3 + white * 0.3104856
                b4 = 0.55000 * b4 + white * 0.5329522
                b5 = -0.7616 * b5 - white * 0.0168980
                value = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
                b6 = white * 0.115926
            else:
                # A leaky integrator: -6 dB/octave, without the DC drift of a pure random walk.
                brown = 0.998 * brown + white * 0.06
                value = brown
            out[i * CHANNELS + c] = value
    return out


def credit_entry(sound):
    name, url = LICENSES[sound["license"]]
    return {
        "title": sound["work"],
        "author": sound["author"],
        "url": sound["url"],
        "license": sound["license"],
        "licenseName": name,
        "licenseURL": url,
        "editedBy": sound["editedBy"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--ffmpeg")
    parser.add_argument("--cache", default=os.path.join(os.path.expanduser("~"), ".cache", "pomodoro-ambient"))
    args = parser.parse_args()

    ffmpeg = find_ffmpeg(args.ffmpeg)
    print(f"using {ffmpeg_version(ffmpeg)}")
    os.makedirs(args.cache, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    for name in os.listdir(OUT_DIR):
        if name.endswith(".m4a"):
            os.remove(os.path.join(OUT_DIR, name))

    entries = []
    for sound in RECORDED:
        assert sound["license"] in ALLOWED_SOURCE_LICENSES, sound["id"]
        print(f"{sound['id']}:")
        source = fetch(sound, args.cache)
        available = probe_frames(ffmpeg, source)
        # Short clips give up less of their length to the seam.
        seam = min(int(SEAM_SECONDS["recorded"] * RATE), available // 5)
        frames, loop = loop_frames(available, seam)
        samples, measured = normalised_pcm(ffmpeg, ["-i", source], frames)
        entries.append(finish(ffmpeg, sound, samples, seam, loop, measured, {
            "kind": "blanket",
            "repository": BLANKET_REPO,
            "commit": BLANKET_COMMIT,
            "path": "data/resources/sounds/" + sound["file"],
            "url": BLANKET_RAW + sound["file"],
            "sha256": sound["sha256"],
        }, credit_entry(sound)))

    for spec in NOISES:
        print(f"{spec['id']}:")
        seam = int(SEAM_SECONDS["noise"] * RATE)
        frames, loop = loop_frames(int(NOISE_SECONDS * RATE) + seam, seam)
        raw = noise(spec["color"], spec["seed"], frames)
        raw_path = os.path.join(args.cache, spec["id"] + ".f32")
        with open(raw_path, "wb") as f:
            raw.tofile(f)
        # The integrator still wanders at sub-audio rates, which only wastes headroom.
        prefilter = "highpass=f=20," if spec["color"] == "brown" else ""
        samples, measured = normalised_pcm(ffmpeg, [*RAW_IN, "-i", raw_path], frames, prefilter)
        entries.append(finish(ffmpeg, spec, samples, seam, loop, measured, {
            "kind": "generated",
            "generator": "scripts/import_ambient.py",
            "color": spec["color"],
            "seed": spec["seed"],
        }, None))

    total = sum(e["bytes"] for e in entries)
    print(f"total {total / 1024 / 1024:.2f} MiB for {len(entries)} sounds")
    if total > BUDGET_BYTES:
        sys.exit(f"over the {BUDGET_BYTES // 1024 // 1024} MiB budget")
    for e in entries:
        del e["bytes"]

    manifest = {
        "version": 1,
        "format": {"codec": "aac", "bitrate": BITRATE, "sampleRate": RATE, "channels": CHANNELS,
                   "loudness": f"{LOUDNESS['I']} LUFS integrated, {LOUDNESS['TP']} dBTP"},
        "sounds": entries,
    }
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    write_licensing(entries)
    print(f"wrote {os.path.relpath(MANIFEST, ROOT)} and {os.path.relpath(LICENSING, ROOT)}")


def finish(ffmpeg, spec, samples, seam, loop, measured, source, credit):
    looped = crossfade_seam(samples, seam)
    assert len(looped) == loop * CHANNELS, (spec["id"], len(looped), loop)
    file = spec["id"] + ".m4a"
    path = os.path.join(OUT_DIR, file)
    encode(ffmpeg, looped, path)
    size = os.path.getsize(path)
    decoded = decoded_frames(ffmpeg, path)
    print(f"  {loop / RATE:6.2f} s, {size / 1024:7.1f} KiB, source {measured:+.1f} LUFS, decodes to {decoded} frames")
    return {
        "id": spec["id"],
        "title": spec["title"],
        "symbol": spec["symbol"],
        "file": file,
        "frames": loop,
        "sampleRate": RATE,
        "channels": CHANNELS,
        "duration": round(loop / RATE, 3),
        "source": source,
        "credit": credit,
        "bytes": size,
    }


def write_licensing(entries):
    lines = [
        "# Sounds licensing",
        "",
        "<!-- Generated by scripts/import_ambient.py from App/Resources/Ambient/ambient-credits.json. -->",
        "",
        "The chimes in `App/Resources/Sounds/` and the white, pink and brown noise in",
        "`App/Resources/Ambient/` are original, generated by `scripts/gen_sounds.py` and",
        "`scripts/import_ambient.py`.",
        "",
        "The other ambient sounds come from [Blanket](" + BLANKET_REPO + ") at commit",
        f"[`{BLANKET_COMMIT[:7]}`]({BLANKET_REPO}/tree/{BLANKET_COMMIT}/data/resources/sounds), which",
        "credits each file in its",
        f"[SOUNDS_LICENSING.md]({BLANKET_REPO}/blob/{BLANKET_COMMIT}/SOUNDS_LICENSING.md). Only files",
        "licensed CC0, Public Domain or CC BY are used. We trimmed each one, normalised its loudness,",
        "crossfaded its loop seam, and re-encoded it as AAC.",
        "",
        "| Sound | Original | Author | Edited by | License |",
        "| --- | --- | --- | --- | --- |",
    ]
    for e in entries:
        credit = e["credit"]
        if credit is None:
            continue
        license = credit["licenseName"]
        if credit["licenseURL"]:
            license = f"[{license}]({credit['licenseURL']})"
        edited = ", ".join(x for x in (credit["editedBy"], "Pomodoro") if x)
        lines.append(f"| {e['title']} | [{credit['title']}]({credit['url']}) | {credit['author']} | {edited} | {license} |")
    lines.append("")
    with open(LICENSING, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
