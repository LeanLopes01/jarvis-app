"""Download the on-device voice models into assets/models (about 110 MB).

    python tool/fetch_voice_models.py

Run it once before building the app; the files are not kept in git. They come
from the sherpa-onnx releases and run fully offline on the phone:

- kws/      "Jarvis" wake-word spotter (zipformer, GigaSpeech, 3.3M parameters)
- vad/      Silero voice activity detector (end of the spoken command)
- whisper/  Whisper tiny, multilingual, int8 (transcribes the command)
"""

from __future__ import annotations

import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

RELEASES = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
KWS = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
WHISPER = "sherpa-onnx-whisper-tiny"
# archive -> {member inside the archive: file in assets/models}
ARCHIVES = {
    f"{RELEASES}/kws-models/{KWS}.tar.bz2": {
        f"{KWS}/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx": "kws/encoder.int8.onnx",
        f"{KWS}/decoder-epoch-12-avg-2-chunk-16-left-64.onnx": "kws/decoder.onnx",
        f"{KWS}/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx": "kws/joiner.int8.onnx",
        f"{KWS}/tokens.txt": "kws/tokens.txt",
    },
    f"{RELEASES}/asr-models/{WHISPER}.tar.bz2": {
        f"{WHISPER}/tiny-encoder.int8.onnx": "whisper/tiny-encoder.int8.onnx",
        f"{WHISPER}/tiny-decoder.int8.onnx": "whisper/tiny-decoder.int8.onnx",
        f"{WHISPER}/tiny-tokens.txt": "whisper/tiny-tokens.txt",
    },
}
FILES = {f"{RELEASES}/asr-models/silero_vad.onnx": "vad/silero_vad.onnx"}


def download(url: str, target: Path) -> None:
    print(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=60) as response, target.open("wb") as out:
        shutil.copyfileobj(response, out)


def main() -> None:
    models = Path(__file__).resolve().parents[1] / "assets" / "models"
    wanted = [models / name for files in ARCHIVES.values() for name in files.values()]
    wanted += [models / name for name in FILES.values()]
    if all(path.exists() for path in wanted) and "--force" not in sys.argv:
        print(f"models already in {models}")
        return
    with tempfile.TemporaryDirectory() as tmp:
        for url, members in ARCHIVES.items():
            archive = Path(tmp) / url.rsplit("/", 1)[1]
            download(url, archive)
            with tarfile.open(archive, "r:bz2") as tar:
                for member, name in members.items():
                    # Only the named regular files are read; nothing else is extracted.
                    info = tar.getmember(member)
                    source = tar.extractfile(info) if info.isfile() else None
                    if source is None:
                        raise SystemExit(f"{member} is missing from {url}")
                    target = models / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source, target.open("wb") as out:
                        shutil.copyfileobj(source, out)
        for url, name in FILES.items():
            target = models / name
            target.parent.mkdir(parents=True, exist_ok=True)
            download(url, target)
    total = sum(path.stat().st_size for path in wanted)
    print(f"done: {len(wanted)} files, {total / 1e6:.0f} MB in {models}")


if __name__ == "__main__":
    main()
