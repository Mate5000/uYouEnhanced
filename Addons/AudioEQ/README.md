# Audio EQ for uYouEnhanced

This module is compiled directly into `uYouEnhanced.dylib`. It has no YouTube
Plus/YTLite dependency, subscription, activation service, or network requests.
The existing uYou, download, PiP, theme, SponsorBlock and other integrations stay
in the normal uYouEnhanced build.

## Open the equalizer

- **YouTube settings → uYouEnhanced → Video player options → Audio EQ**.
- **Video player gear → Audio EQ** opens the same panel and saved configuration.

The panel follows light/dark appearance and includes Hungarian and English.
Turn on the master switch and Bass boost, Equalizer, or both. All switches start
off, and the ten EQ bands start at zero. Settings persist across app launches in
the separate `com.ytaudioeq.preferences` suite.

| Control | Range | Initial value |
| --- | --- | --- |
| Bass frequency (shelf midpoint) | 30–200 Hz | 80 Hz |
| Bass gain | 0 to Max gain | +4 dB |
| Max gain | 0–18 dB | 12 dB |
| EQ bands | −12 to +12 dB each | 0 dB |

The frequencies are 31.5, 63, 125, 250, 500 Hz, 1, 2, 4, 8, and 16 kHz.
Lowering Max gain clamps Bass gain immediately. Reset equalizer only clears the
bands; Reset all restores the initial values and switches everything off.

The bass filter is a broad monotonic low shelf. The combined EQ/bass response
determines automatic headroom, followed by a linked-stereo −1 dBFS sample-peak
limiter. Overall volume may reduce when boosts are applied. Filter changes
crossfade over 20 ms. This is digital clipping protection, not a true-peak limiter
or a guarantee against physical speaker distortion.

## Build the app

Use this **uYouEnhanced repository** as the fork/build root, rather than the
parent YTLite project. In **Actions → Build and Release uYouEnhanced**, keep
**Include 10-band Audio EQ and bass boost** checked and provide your clean,
decrypted YouTube IPA link. Keep the existing FFmpeg source-build option enabled
for the complete conversion/download backend. Sign/install the resulting IPA
with your usual sideloading tool; the workflow does not provide an app-signing
certificate.

For a configured local macOS/Theos checkout with initialized submodules:

```sh
git submodule update --init --recursive
make package THEOS_PACKAGE_SCHEME=rootless IPA=/path/to/YouTube.ipa \
    SDK_VERSION=26.5 AUDIO_EQ_ENABLED=1 FINALPACKAGE=1
```

Use `AUDIO_EQ_ENABLED=0`, or uncheck the workflow option, to build without the
EQ code, resources and menu row. The existing feature switches are independent.
Do not additionally inject the old standalone `YTAudioEQ.dylib`: this build
already contains its code, and loading both would duplicate hooks/classes.

The final IPA is checked for its actual dylib load commands, the embedded EQ
classes, both translations, license notice, the main uYou engine and selected
features. When FFmpeg is requested, all eight framework executables must be in
the media bundle. These checks verify packaging, not playback on an iPhone.

## How it integrates

The native settings row calls `YTAEQCreatePanel()` directly. The app build omits
`StandaloneSettings.xm`, so it does not compete with uYouEnhanced/YouGroupSettings
for category registration. The development target also omits this file when
`YTAEQ_EMBEDDED=1`. The
player-gear bridge appends its action without reordering existing actions.

The audio adapters operate in the app, before the original renderer receives
the output: copied sample buffers with system AudioConverter decoding when
needed, or a post-render RemoteIO notify. Import rebinding is restricted to the
app and its embedded frameworks; no executable-code patch or system-wide audio
service is used. The fallback avoids processing a sample-renderer stream twice.
Each stream has its own filter/decoder state. Settings mailboxes and the output
registry are initialized before hooks start, independently of C++ constructor
ordering in the combined dylib.

The compressed adapter drains each input batch until its callback reports
temporary starvation. That is a normal streaming boundary, not end-of-stream:
the converter keeps its history for the next batch. On the reported Opus feed,
the first 9600 input frames yielded 9480 PCM frames. The adapter compensates the
120-frame startup delay once with leading silence (2.5 ms at 48 kHz), keeping
the original sample-buffer timestamps and durations. Further decoded samples
flow in order; any extra output is carried forward. Startup delay/carry is capped
at 20 ms, and recurring short output still fails safely rather than inserting
silence repeatedly. The final decoder delay is not explicitly drained because
the enqueue hook has no reliable end-of-stream notification; up to that bounded
delay can remain at the end of a stream. Device listening/sync checks remain
required.

Once a compressed stream is being decoded, disabling the effects keeps dry PCM
flowing through the same decoder. This avoids re-priming on every switch change.
Before the first activation, bypass passes the original sample buffers through.
Flush, seek, format change and genuine failure clear the decoder/carry. The real
time render callback is unchanged; codec/storage work stays on the producer queue.

Unsupported codecs/layouts, invalid timestamps or decoder failures pass original
audio through. The status row only reports active processing after an active DSP
chain has actually processed buffers. Existing playback engines are not replaced
or rerouted. System/framework support determines whether a particular stream
can be processed; downloaded media in uYou's separate player needs its own device
check. AirPlay and Cast are outside the supported scope. Changes apply to newly
submitted audio, so prequeued buffers can delay when a slider change is heard.

## Verification

### On-device diagnostics

In either EQ panel, open **Diagnostics → Show detailed diagnostics**, or use
**Copy diagnostics**. The screen refreshes once per second; the report also
contains the YouTube/iOS versions, output route, effect settings, codec FourCC,
source format, converter priming status, expected/returned PCM frames,
available/consumed/requested packets, hook callback counters and the precise
last failing API. The failure stage and OSStatus are captured together in one
lock-free word. Formatting and copying happen on the UI thread.

`2037671281` (`'yteq'`) means our converter input callback ran out of packets.
Build 1.0.1 rejected the valid short first Opus output and reset on every batch.
Build **1.0.2-opus-streaming** accepts the bounded startup delay and preserves the
converter. The optional priming property can still return `'prop'`; this alone
does not prevent processing. See Apple's
[input callback contract](https://developer.apple.com/documentation/audiotoolbox/audioconvertercomplexinputdataproc).
The report now includes successful decoder continuations, startup padding and
queued PCM frames. Input-exhaustion counts can increase during normal processing;
decoder resets must not increase with every batch. After reproducing a failure, copy the
report while playback is running. A report with zero processed PCM frames must
not be interpreted as a working EQ. Historical failure details are retained
even if later buffers recover; all counters cover the current app session.

Static inspection of the supplied YouTube 21.07.4 IPA confirmed the
`AVSampleBufferAudioRenderer` import, `HAMSBARAudioTrackRenderer` class and
chained fixups. Legacy fishhook rebinding does not walk chained fixups, so its
setup alone cannot establish that the RemoteIO fallback intercepts playback.
The report distinguishes setup attempts from actually observed callbacks.

The app's adblock preference initialization now happens before its hooks are
selected, and player-response getters/counts are replaced rather than merely
added. Existing choices remain saved. This does not establish compatibility
with every server-side ad delivery variation; check playback on the device.

```sh
bash Tools/test-audio-eq.sh
python3 Scripts/audio-eq/verify_ipa.py packages/your-build.ipa \
    --audio-eq 1 --ffmpeg 1 --sponsorblock 0 --ytuhd 0
```

The `Audio EQ checks` workflow runs portable DSP/PCM tests, including the observed
9600/9480 startup regression, sample-order/carry and mono/stereo 44.1/48 kHz cases,
package-verifier tests, and Theos builds of standalone and embedded modes. macOS
also runs `Tools/test-audio-decoder-apple.sh`: the production adapter decodes our
own synthetic mono/stereo Opus packets using Apple's actual codec, checks
continuous PTS/duration and measures the relative bass increase. This check also
runs before the normal IPA build on macOS; it is not executed on Windows/Linux.
The standalone `.deb` is a development artifact; the normal app build embeds EQ in
the main tweak instead of injecting this package.

The full macOS app build needs Xcode, the selected SDK, all existing submodules
and a decrypted YouTube IPA. Do not claim device compatibility from a successful
DSP test, compilation or archive check alone. Required iPhone checks:

- Open both entry points in normal/fullscreen playback; check light/dark mode,
  Hungarian/English, larger text, persistence, gain clamping and both resets.
- Compare bypass and bass/EQ with music, speech and known test tones. Capture
  output and confirm the relative frequency response, accounting for headroom.
- Test video, Shorts, background/locked-screen playback, seeks, new videos,
  audio-track changes, interruptions and speaker/wired/Bluetooth route changes.
- Confirm original uYou downloads, conversion, downloaded-media playback, PiP,
  SponsorBlock (when selected), themes and other enabled tweaks still behave as
  expected. Test with EQ enabled, disabled, and excluded at build time.
- Watch the status: an unsupported or unobserved audio route must remain audible
  and must not be presented as confirmed processing.

## Third-party source

`Vendor/fishhook.c` and `.h` are from
[facebook/fishhook at aadc161ac3b80db07a9908851839a17ba63a9eb1](https://github.com/facebook/fishhook/tree/aadc161ac3b80db07a9908851839a17ba63a9eb1).
The BSD license is retained alongside the source and inside the resource bundle
as `ThirdPartyNotices.txt`. Its C symbols are prefixed at compile time.
