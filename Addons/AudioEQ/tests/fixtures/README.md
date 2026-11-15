# Synthetic Opus fixtures

These are newly generated test tones, not recordings: 2 seconds of 63 Hz + 1 kHz,
each with amplitude 0.1, at 48 kHz. The right channel is scaled by 0.7. Each file
contains 100 raw 20 ms packets encoded using libopus 1.5.2 in restricted-low-delay
(CELT) mode. No codec implementation is shipped in the tweak.

Format: ASCII `YTEQOPUS`, little-endian uint32 sample rate, channel count, packet
count, then for each packet a little-endian uint32 size followed by packet bytes.
No OpusHead or cookie is supplied, matching the reported YouTube 21.07.4 stream.

Regenerate with `../generate-opus-fixture.py /path/to/libopus.so .`.
The [official 1.5.2 source](https://opus-codec.org/release/stable/2024/04/12/libopus-1_5_2.html)
has SHA256 `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1`.

The Apple test includes the production adapter and tests actual decoded samples,
relative bass gain, matching timestamps/durations, disable/re-enable, seek and
flush. It substitutes only hook installation and the final renderer enqueue;
AudioConverter and CoreMedia are the real system APIs. It does not test Bluetooth
hardware, YouTube's renderer or an iPhone's version of the system codec.
