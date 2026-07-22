#!/usr/bin/env python3
"""Generate and time-align the Plant Talk demo narration with MiniMax TTS."""

import binascii
import json
import os
import subprocess
import urllib.error
import urllib.request
from pathlib import Path


OUTPUT_DIR = Path("/Users/mayifan/Desktop/dev submission/plant-talk-voiceover-v2")
MODEL = "speech-2.8-hd"
VOICE_ID = "English_expressive_narrator"
SAMPLE_RATE = 44100
END_PAUSE_SECONDS = 0.6

SEGMENTS = [
    (1, 18, "Hi, this is Plant Talk, an iOS app that lets you talk with a real plant. An ESP32 measures temperature, humidity, soil conditions, and light. GPT five point six combines those live signals with conversation and memory, so its advice is grounded in the plant's actual environment."),
    (2, 19, "The interface centers on a Mesh Gradient orb. With Codex, I analyzed a reference animation frame by frame, rebuilt the effect in SwiftUI, and connected its movement to live audio energy. The orb now responds to both the user's voice and the model's spoken reply."),
    (3, 18, "I first mapped the interface and component hierarchy in Apple Freeform. Codex then helped me translate that design into adaptive SwiftUI, including the plant artwork, sensor cards, conversation entry, dark mode, and Liquid Glass surfaces, instead of relying on fixed screen coordinates."),
    (4, 23, "Codex was also my animation partner. We analyzed iMessage recordings at sixty frames per second, replaced a fragile matched-geometry transition with a dedicated message-flight overlay, and refined the chat bubbles, the bottom menu in Text Conversation View, and the camera, photo-picker, and button animations through repeated simulator and real-device tests."),
    (5, 19, "Plant Talk is local-first. SQLite stores sensor history, conversations, tool calls, and long-term memory. Durable cursors and unique device-sequence keys prevent skipped or duplicated records. This gives GPT five point six reliable historical context while the raw plant data remains on the phone."),
    (6, 20, "The physical layer uses an ESP32 with temperature, humidity, soil, and light sensors. It samples every five minutes and syncs batches over Bluetooth. Codex helped me identify packet-loss risks, add CRC and range validation, and acknowledge data only after the SQLite transaction commits."),
    (7, 18, "Now for the live demo. First, I ask for a fresh reading. GPT five point six calls an on-demand sampling tool, the ESP32 measures the environment immediately, and the model turns the new values into care advice based on what the plant is experiencing right now."),
    (8, 16, "Next, I ask what changed most during the last twenty-four hours. GPT five point six combines the live Bluetooth reading with SQLite history, selects the appropriate summary and trend tools, and prioritizes the care action supported by the largest environmental change."),
    (9, 21, "Finally, I ask for a seven-day assessment. The model checks temperature, humidity, soil-sensor, and light trends, verifies data coverage, identifies possible stress patterns, and produces an evidence-based three-step care plan. Plant Talk turns sensing, memory, tool use, and GPT five point six reasoning into practical, personalized plant care."),
]


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def duration(path):
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(result.stdout.strip())


def synthesize(api_key, text, destination):
    payload = {
        "model": MODEL,
        "text": text,
        "stream": False,
        "language_boost": "English",
        "output_format": "hex",
        "voice_setting": {
            "voice_id": VOICE_ID,
            "speed": 1.0,
            "vol": 1.0,
            "pitch": 0,
        },
        "audio_setting": {
            "sample_rate": 32000,
            "bitrate": 128000,
            "format": "mp3",
            "channel": 1,
        },
    }
    request = urllib.request.Request(
        "https://api.minimaxi.com/v1/t2a_v2",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        message = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"MiniMax HTTP {error.code}: {message[:500]}") from error
    status = body.get("base_resp", {})
    if status.get("status_code") != 0:
        raise RuntimeError(f"MiniMax error: {status}")
    audio_hex = body.get("data", {}).get("audio")
    if not audio_hex:
        raise RuntimeError("MiniMax returned no audio data")
    destination.write_bytes(binascii.unhexlify(audio_hex))


def main():
    api_key = os.environ.get("MINIMAX_API_KEY")
    if not api_key:
        raise SystemExit("MINIMAX_API_KEY is not available in this shell")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    concat_lines = []
    timing_rows = []
    cursor = 0.0

    for slide, target_seconds, text in SEGMENTS:
        raw_path = OUTPUT_DIR / f"slide-{slide:02d}-raw.mp3"
        timed_path = OUTPUT_DIR / f"slide-{slide:02d}-{target_seconds:02d}s.wav"
        if raw_path.exists():
            print(f"Reusing slide {slide} synthesis...", flush=True)
        else:
            print(f"Synthesizing slide {slide}...", flush=True)
            synthesize(api_key, text, raw_path)
        raw_seconds = duration(raw_path)
        speech_target = target_seconds - END_PAUSE_SECONDS
        tempo = raw_seconds / speech_target
        if not 0.5 <= tempo <= 2.0:
            raise RuntimeError(f"Slide {slide} needs unsupported tempo adjustment {tempo:.3f}")
        run(
            "ffmpeg", "-y", "-i", str(raw_path),
            "-af", f"atempo={tempo:.8f},apad=whole_dur={target_seconds},atrim=duration={target_seconds}",
            "-ar", str(SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le", str(timed_path),
        )
        actual = duration(timed_path)
        concat_lines.append(f"file '{timed_path.name}'")
        timing_rows.append({
            "slide": slide,
            "start": round(cursor, 3),
            "end": round(cursor + target_seconds, 3),
            "target_seconds": target_seconds,
            "raw_seconds": round(raw_seconds, 3),
            "tempo_factor": round(tempo, 5),
            "actual_seconds": round(actual, 3),
            "text": text,
        })
        cursor += target_seconds

    concat_file = OUTPUT_DIR / "concat.txt"
    concat_file.write_text("\n".join(concat_lines) + "\n", encoding="utf-8")
    master_wav = OUTPUT_DIR / "Plant-Talk-demo-voiceover-2m52s.wav"
    master_mp3 = OUTPUT_DIR / "Plant-Talk-demo-voiceover-2m52s.mp3"
    run("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat_file), "-c", "copy", str(master_wav))
    run("ffmpeg", "-y", "-i", str(master_wav), "-c:a", "libmp3lame", "-b:a", "192k", str(master_mp3))

    timing = {
        "model": MODEL,
        "voice_id": VOICE_ID,
        "total_target_seconds": int(cursor),
        "master_wav_seconds": round(duration(master_wav), 3),
        "master_mp3_seconds": round(duration(master_mp3), 3),
        "segments": timing_rows,
    }
    (OUTPUT_DIR / "timing-report.json").write_text(json.dumps(timing, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(timing, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
