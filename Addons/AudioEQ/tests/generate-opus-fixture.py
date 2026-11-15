"""Generate our own 2-second 63 Hz + 1 kHz signal with libopus 1.5.2.

Usage: python3 generate-opus-fixture.py /path/to/libopus.so fixtures
Only used to regenerate test assets; the tweak has no libopus dependency.
"""
import ctypes as c
import math
from pathlib import Path
import struct
import sys

lib = c.CDLL(sys.argv[1])
lib.opus_encoder_create.argtypes = [c.c_int32, c.c_int, c.c_int, c.POINTER(c.c_int)]
lib.opus_encoder_create.restype = c.c_void_p
lib.opus_encoder_destroy.argtypes = [c.c_void_p]
lib.opus_encode_float.argtypes = [c.c_void_p, c.POINTER(c.c_float), c.c_int, c.POINTER(c.c_ubyte), c.c_int32]
lib.opus_encode_float.restype = c.c_int32
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)
for channels in (1, 2):
    error = c.c_int()
    # OPUS_APPLICATION_RESTRICTED_LOWDELAY = 2051, CELT mode like the reported
    # 120-frame decoder delay. No external recording or copyrighted audio.
    encoder = lib.opus_encoder_create(48000, channels, 2051, c.byref(error))
    assert encoder and error.value == 0
    data = bytearray(b"YTEQOPUS" + struct.pack("<III", 48000, channels, 100))
    for packet in range(100):
        pcm = (c.c_float * (960 * channels))()
        for i in range(960):
            t = (packet * 960 + i) / 48000
            value = 0.1 * math.sin(2 * math.pi * 63 * t) + 0.1 * math.sin(2 * math.pi * 1000 * t)
            for channel in range(channels):
                pcm[i * channels + channel] = value * (1 if channel == 0 else 0.7)
        encoded = (c.c_ubyte * 4000)()
        size = lib.opus_encode_float(encoder, pcm, 960, encoded, len(encoded))
        assert size > 0
        data += struct.pack("<I", size) + bytes(encoded[:size])
    lib.opus_encoder_destroy(encoder)
    path = destination / f"tones-48k-{channels}ch.opus-packets"
    path.write_bytes(data)
    print(f"Generated {path.name}: {len(data)} bytes")
