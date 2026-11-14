"""Check the final uYouEnhanced IPA without extracting or changing it.

This verifies embedded code/resources and retained features, not device playback.
Only Python's standard library is required.
"""
import argparse
import plistlib
import struct
import zipfile
from pathlib import PurePosixPath

CORE_LIBRARIES = (
    "uYouEnhanced.dylib", "uYou.dylib", "YouGroupSettings.dylib", "YouPiP.dylib",
    "YouTubeDislikesReturn.dylib", "YouMute.dylib",
)
FFMPEG_LIBRARIES = (
    "ffmpegkit", "libavcodec", "libavdevice", "libavfilter", "libavformat",
    "libavutil", "libswresample", "libswscale",
)
EQ_CLASS_MARKERS = (b"YTAEQViewController", b"YTAEQSampleState")


def dylib_references(data):
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = data[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack_from(">I", data, 4)[0]
        for index in range(count):
            start = 8 + index * (32 if wide else 20)
            cpu = struct.unpack_from(">I", data, start)[0]
            offset, length = struct.unpack_from(">QQ" if wide else ">II", data, start + 8)
            if cpu == 0x0100000C:
                if offset + length > len(data):
                    raise ValueError("Invalid arm64 Mach-O slice")
                return dylib_references(data[offset:offset + length])
        raise ValueError("No arm64 slice in Mach-O")
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a 64-bit arm64 Mach-O")
    cpu, _, _, count, size = struct.unpack_from("<IIIII", data, 4)
    if cpu != 0x0100000C or 32 + size > len(data):
        raise ValueError("Invalid arm64 Mach-O header")
    offset, references = 32, []
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError("Invalid Mach-O load command")
        if command in (0xC, 0x80000018, 0x8000001F, 0x20):
            if length < 24:
                raise ValueError("Invalid dylib command")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if name_offset < 24 or name_offset >= length:
                raise ValueError("Invalid dylib name")
            references.append(data[offset + name_offset:offset + length].split(b"\0", 1)[0].decode())
        offset += length
    return references


def verify_ipa(path, *, audio_eq=True, ffmpeg=False, sponsorblock=False, ytuhd=False):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        plists = [name for name in names if name.startswith("Payload/") and
                  len(PurePosixPath(name).parts) == 3 and name.endswith(".app/Info.plist")]
        if len(plists) != 1:
            raise ValueError("Expected one main app Info.plist")
        app = PurePosixPath(plists[0]).parent
        info = plistlib.loads(archive.read(plists[0]))
        executable = info["CFBundleExecutable"]
        if PurePosixPath(executable).name != executable:
            raise ValueError("Invalid CFBundleExecutable")
        app_names = [name for name in names if name.startswith(str(app) + "/") and "/PlugIns/" not in name]
        references = [PurePosixPath(name).name for name in dylib_references(archive.read(str(app / executable))) ]

        def unique_file(suffix):
            matches = [name for name in app_names if name == str(app / suffix) or name.endswith("/" + suffix)]
            if len(matches) != 1:
                raise ValueError(f"Expected exactly one {suffix}, found {len(matches)}")
            return matches[0]

        required = list(CORE_LIBRARIES)
        if sponsorblock:
            required.append("iSponsorBlock.dylib")
        if ytuhd:
            required.append("YTUHD.dylib")
        for library in required:
            unique_file(library)
            if references.count(library) != 1:
                raise ValueError(f"App must load {library} exactly once")
        unique_file("uYouPlus.bundle/Info.plist")
        unique_file("uYouBundle.bundle/Info.plist")

        enhancer = archive.read(unique_file("uYouEnhanced.dylib"))
        standalone = [name for name in app_names if PurePosixPath(name).name == "YTAudioEQ.dylib"]
        if standalone:
            raise ValueError("Separate YTAudioEQ.dylib found; use a clean YouTube IPA to avoid duplicate audio hooks")
        if audio_eq:
            for marker in EQ_CLASS_MARKERS:
                if marker not in enhancer:
                    raise ValueError(f"Embedded EQ code missing: {marker.decode()}")
            for suffix in ("Info.plist", "en.lproj/Localizable.strings", "hu.lproj/Localizable.strings", "ThirdPartyNotices.txt"):
                unique_file("YTAudioEQ.bundle/" + suffix)
        elif any(marker in enhancer for marker in EQ_CLASS_MARKERS):
            raise ValueError("EQ code is present although AUDIO_EQ_ENABLED=0")
        elif any("/YTAudioEQ.bundle/" in name for name in app_names):
            raise ValueError("EQ resources are present although AUDIO_EQ_ENABLED=0")
        if ffmpeg:
            for library in FFMPEG_LIBRARIES:
                unique_file(f"uYouMedia.bundle/{library}.framework/{library}")
    return {"audio_eq": audio_eq, "required_libraries": required, "ffmpeg": ffmpeg}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    for name, default in (("audio-eq", "1"), ("ffmpeg", "0"), ("sponsorblock", "0"), ("ytuhd", "0")):
        parser.add_argument("--" + name, choices=("0", "1"), default=default)
    options = parser.parse_args()
    try:
        result = verify_ipa(options.ipa, audio_eq=options.audio_eq == "1", ffmpeg=options.ffmpeg == "1",
                            sponsorblock=options.sponsorblock == "1", ytuhd=options.ytuhd == "1")
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, struct.error) as error:
        raise SystemExit(f"IPA verification failed: {error}") from error
    print(f"PASS: uYouEnhanced IPA features verified: {result}")


if __name__ == "__main__":
    main()
