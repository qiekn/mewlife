"""Import a small, traced OOTSS sound bank and the Priestess animation cue markers.

This is deliberately a v154/demo-specific extractor, not a Wwise runtime. It selects
granite / crystal / cleric switches and three deterministic random-container variants.
Wwise DSP, RTPCs and ambience are not imported. All writes stay in --output and .build.
"""

from pathlib import Path
import argparse
import array
import hashlib
import json
import math
import re
import shutil
import struct
import subprocess
import sys
import wave


EVENTS = {
    "step": "char_cleric_anim_step_slowMoOnly",
    "foot_stop": "char_cleric_anim_footStop",
    "foot_stop_soft": "char_cleric_anim_footStop_lo",
    "cloth": "char_cleric_anim_cloth",
    "stick_slide": "char_cleric_anim_stickSlide",
    "push": "push_block",
    "push_failed": "no_multipush",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def u32(data, offset=0):
    return struct.unpack_from("<I", data, offset)[0]


def sound_id(name):
    value = 2166136261
    for char in name.lower().encode("ascii"):
        value = ((value * 16777619) & 0xffffffff) ^ char
    return value


def bank_chunks(path):
    data = path.read_bytes()
    offset = 0
    chunks = {}
    while offset < len(data):
        require(offset + 8 <= len(data), "Truncated sound-bank chunk")
        name, size = struct.unpack_from("<4sI", data, offset)
        offset += 8
        require(size <= len(data) - offset, "Sound-bank chunk exceeds file")
        chunks[name] = data[offset:offset + size]
        offset += size
    require(u32(chunks[b"BKHD"]) == 154, "This importer supports the local Wwise v154 demo banks")
    return chunks


class Sound_Bank:
    def __init__(self, folder):
        self.folder = folder
        bank = bank_chunks(folder / "Gameplay_and_characters.bnk")
        block = bank[b"HIRC"]
        self.objects = {}
        offset = 4
        for _ in range(u32(block)):
            kind, length, ident = struct.unpack_from("<BII", block, offset)
            require(length >= 4 and offset + 5 + length <= len(block), "Invalid HIRC object")
            self.objects[ident] = (kind, block[offset + 9:offset + 5 + length])
            offset += 5 + length
        require(offset == len(block), "Unexpected HIRC tail")
        media = bank_chunks(folder / "Gameplay_and_characters_media.bnk")
        self.media = {ident: media[b"DATA"][offset:offset + size]
                      for ident, offset, size in struct.iter_unpack("<III", media[b"DIDX"])}
        self.children = {}
        for ident, (kind, raw) in self.objects.items():
            # In this bank these selected nodes have no FX attachment. Sound source headers are 18 bytes.
            base = 18 if kind == 2 else 0
            if kind not in (2, 5, 6, 7, 9) or raw[base:base + 4] != b"\0" * 4:
                continue
            parent = u32(raw, base + 8)
            if parent in self.objects and struct.pack("<I", ident) in self.objects[parent][1]:
                self.children.setdefault(parent, []).append(ident)
        self.decoded = {}

    def switch(self, ident, raw, include_slow_steps):
        groups = {
            sound_id("switch_surfacematerial"): ("switch_surfacematerial", "granite"),
            sound_id("switch_object_type"): ("switch_object_type", "crystal"),
            sound_id("state_timeRate"): ("state_timeRate", "zero"),
            2805662815: ("character switch", "cleric"),
        }
        found = [(raw.find(struct.pack("<I", group)), group) for group in groups]
        found = [(offset, group) for offset, group in found if offset >= 0]
        # The same group ID may also occur earlier in an RTPC curve; only the switch table
        # is followed by the reciprocal child list, so don't mistake a curve for a selector.
        declared_children = set(self.children.get(ident, []))
        found = [(offset, group) for offset, group in found
                 if offset + 13 + 4 * len(declared_children) <= len(raw)
                 and u32(raw, offset + 9) == len(declared_children)
                 and {u32(raw, offset + 13 + 4 * i) for i in range(len(declared_children))} == declared_children]
        require(len(found) == 1, f"Unknown or ambiguous switch on HIRC node {ident}")
        base, group = found[0]
        name, state = groups[group]
        offset = base + 9  # group ID, default state, continuous-validation byte
        count = u32(raw, offset)
        offset += 4
        declared = [u32(raw, offset + 4 * i) for i in range(count)]
        offset += count * 4
        require(set(declared) == set(self.children.get(ident, [])), f"Unparsed switch children on {ident}")
        count = u32(raw, offset)
        offset += 4
        states = {}
        for _ in range(count):
            key, length = struct.unpack_from("<II", raw, offset)
            offset += 8
            states[key] = [u32(raw, offset + 4 * i) for i in range(length)]
            offset += length * 4
        require(sound_id(state) in states, f"Missing {state} state on {ident}")
        selected = states[sound_id(state)]
        if name == "state_timeRate" and include_slow_steps:
            # The original game uses these particular footfalls only in slow motion.
            # Our own animation clock schedules their underlying granite sounds at all speeds.
            choices = {tuple(items) for items in states.values() if items}
            require(len(choices) == 1, "Ambiguous slow-motion footstep source")
            selected = list(choices.pop())
            state = "underlying slow-motion footsteps (host owns timing)"
        return selected, {"node": ident, "group": name, "state": state, "children": selected}

    def resolve(self, event, variant):
        decisions = []
        def walk(ident, path):
            require(ident not in path, "Cyclic sound hierarchy")
            kind, raw = self.objects[ident]
            path = path + [ident]
            if kind == 2:
                require(u32(raw) == 0x00040001 and raw[4] == 0, "Expected embedded Wwise Vorbis source")
                media = u32(raw, 5)
                require(media in self.media and len(self.media[media]) == u32(raw, 13), "Missing or truncated WEM")
                return [{"path": path, "media_id": media}]
            if kind == 4:
                require(len(raw) == 1 + raw[0] * 4, "Unsupported event action count")
                children = [u32(raw, 1 + i * 4) for i in range(raw[0])]
            elif kind == 3:
                children = [u32(raw, 2)] if raw[:2] == b"\x03\x04" else []
            elif kind == 6:
                children, decision = self.switch(ident, raw, event == EVENTS["step"])
                decisions.append(decision)
            elif kind in (5, 7, 9):
                children = sorted(self.children.get(ident, []))
                require(children, f"Unparsed container {ident}")
                if kind == 5:
                    children = [children[variant % len(children)]]
            else:
                raise ValueError(f"Unsupported sound node {ident}, type {kind}")
            return [source for child in children for source in walk(child, path)]
        sources = walk(sound_id(event), [])
        require(sources, f"No audio source for {event}")
        return sources, decisions

    def decode(self, media_id, staging, decoder, ffmpeg):
        if media_id in self.decoded:
            return self.decoded[media_id]
        source = staging / f"{media_id}.wem"
        source.write_bytes(self.media[media_id])
        decoded = source.with_suffix(".decoded.wav")
        normalized = source.with_suffix(".wav")
        subprocess.run([decoder, "-o", str(decoded), str(source)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run([ffmpeg, "-v", "error", "-y", "-i", str(decoded), "-ac", "2", "-ar", "48000",
                        "-c:a", "pcm_s16le", str(normalized)], check=True)
        with wave.open(str(normalized), "rb") as stream:
            require(stream.getsampwidth() == 2 and stream.getnchannels() == 2, "Expected 16-bit stereo WAV")
            samples = array.array("h", stream.readframes(stream.getnframes()))
        if sys.byteorder != "little":
            samples.byteswap()
        self.decoded[media_id] = samples
        return samples


def mix_sources(bank, sources, path, staging, decoder, ffmpeg):
    layers = [bank.decode(source["media_id"], staging, decoder, ffmpeg) for source in sources]
    mixed = [0.0] * max(map(len, layers))
    gain = 1 / math.sqrt(len(layers))
    for layer in layers:
        for index, sample in enumerate(layer):
            mixed[index] += sample * gain
    peak = max(map(abs, mixed))
    require(peak > 1, f"Silent sound: {path}")
    attenuation = min(1.0, 0.9 * 32767 / peak)
    pcm = array.array("h", (round(sample * attenuation) for sample in mixed))
    if sys.byteorder != "little":
        pcm.byteswap()
    with wave.open(str(path), "wb") as stream:
        stream.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        stream.writeframes(pcm.tobytes())
    return {"file": path.name, "duration": len(pcm) / (2 * 48000), "layer_gain": gain,
            "peak_attenuation": attenuation, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def import_markers(game, reference, models):
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(reference / "tools"))
    from ootss_formats import Package
    package = Package(game / "data/animation.package")
    manifest = json.loads((models / "manifest.json").read_text())
    imported = {}
    for name, clip in manifest["clips"].items():
        source = f"data/art/animation/soko_cleric/animation/{Path(clip['source']).stem}.sound_events"
        raw = package.read(source) if source in package.entries else b""
        cues = []
        for line in raw.decode("utf-8-sig").splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            match = re.fullmatch(r"(\w+)\s+(\d+(?:\.\d+)?)%", line)
            require(match is not None, f"Unparsed animation cue: {line}")
            event, percentage = match.groups()
            require(event in EVENTS.values(), f"Unmapped Priestess sound cue: {event}")
            cues.append((float(percentage) / 100, event))
        cues.sort()
        with (models / f"{name}.eventsbin").open("wb") as stream:
            stream.write(struct.pack("<4sII", b"MWEV", 1, len(cues)))
            for time, event in cues:
                encoded = event.encode("ascii")
                stream.write(struct.pack("<fI", time, len(encoded)))
                stream.write(encoded)
        imported[name] = {"source": source, "sha256": hashlib.sha256(raw).hexdigest(),
                          "markers": [{"at": time, "event": event} for time, event in cues]}
    return imported


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("assets/audio/ootss"))
    parser.add_argument("--models", type=Path, default=Path("assets/models/priestess"))
    parser.add_argument("--decoder", default=shutil.which("vgmstream-cli"))
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    args = parser.parse_args()
    require(args.decoder and args.ffmpeg, "Install vgmstream-cli and ffmpeg or pass their paths")
    args.output.mkdir(parents=True, exist_ok=True)
    staging = Path(".build/audio_import")
    staging.mkdir(parents=True, exist_ok=True)
    folder = args.game / "data/sound/GeneratedSoundBanks/Windows"
    bank = Sound_Bank(folder)
    manifest = {"source": str(args.game), "bank_version": 154, "format": "PCM16 stereo 48000 Hz",
                "selection": "Granite floor, crystal object, cleric character; three representative variants.",
                "runtime": "Animation markers and world time belong to mewlife; Wwise DSP/RTPCs are omitted.",
                "banks": {name: hashlib.sha256((folder / name).read_bytes()).hexdigest()
                          for name in ["Gameplay_and_characters.bnk", "Gameplay_and_characters_media.bnk"]},
                "sounds": {}}
    for label, event in EVENTS.items():
        variants = []
        for index in range(3):
            sources, decisions = bank.resolve(event, index)
            info = mix_sources(bank, sources, args.output / f"{label}_{index + 1:02d}.wav",
                               staging, args.decoder, args.ffmpeg)
            info["sources"] = [dict(source, sha256=hashlib.sha256(bank.media[source["media_id"]]).hexdigest())
                               for source in sources]
            info["switches"] = decisions
            variants.append(info)
        manifest["sounds"][label] = {"event": event, "event_id": sound_id(event), "variants": variants}
        print(f"{label}: {event}, {len(variants[0]['sources'])} layer(s), "
              f"{', '.join(format(v['duration'], '.2f') + 's' for v in variants)}")
    manifest["animation_markers"] = import_markers(args.game, args.reference, args.models)
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Imported {len(EVENTS) * 3} effects and {len(manifest['animation_markers'])} animation marker tracks.")


if __name__ == "__main__":
    main()
