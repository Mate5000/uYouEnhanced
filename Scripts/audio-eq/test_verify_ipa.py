import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_ipa import CORE_LIBRARIES, EQ_CLASS_MARKERS, FFMPEG_LIBRARIES, dylib_references, verify_ipa


def macho(references=(), extra=b""):
    commands = []
    for reference in references:
        name = reference.encode() + b"\0"
        size = (24 + len(name) + 7) & ~7
        commands.append(struct.pack("<IIIIII", 0xC, size, 24, 0, 0, 0) + name + bytes(size - 24 - len(name)))
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, len(commands), sum(map(len, commands)), 0, 0) + b"".join(commands) + extra


class IPATests(unittest.TestCase):
    def package(self, *, eq=True, skip=(), duplicate=None, reference_skip=(), ffmpeg=False, optional=False, standalone=False, missing_marker=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "uYouEnhanced.ipa"
        root = "Payload/CustomYouTube.app/"
        libraries = list(CORE_LIBRARIES) + (["iSponsorBlock.dylib", "YTUHD.dylib"] if optional else [])
        references = ["@executable_path/Frameworks/" + name for name in libraries if name not in reference_skip]
        if duplicate:
            references.append("@rpath/" + duplicate)
        files = {
            root + "Info.plist": plistlib.dumps({"CFBundleExecutable": "CustomExecutable"}),
            root + "CustomExecutable": macho(references),
            root + "uYouPlus.bundle/Info.plist": plistlib.dumps({}),
            root + "uYouBundle.bundle/Info.plist": plistlib.dumps({}),
        }
        for library in libraries:
            files[root + "Frameworks/" + library] = macho(extra=b"\0".join(marker for marker in EQ_CLASS_MARKERS if marker != missing_marker) if library == "uYouEnhanced.dylib" and eq else b"")
        if eq:
            for suffix in ("Info.plist", "en.lproj/Localizable.strings", "hu.lproj/Localizable.strings", "ThirdPartyNotices.txt"):
                files[root + "YTAudioEQ.bundle/" + suffix] = b"resources"
        if ffmpeg:
            for library in FFMPEG_LIBRARIES:
                files[root + f"uYouMedia.bundle/{library}.framework/{library}"] = macho()
        if standalone:
            files[root + "Frameworks/YTAudioEQ.dylib"] = macho()
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in files.items():
                if not any(part in name for part in skip):
                    archive.writestr(name, data)
        return path

    def test_eq_and_core_features_with_custom_executable(self):
        self.assertTrue(verify_ipa(self.package())["audio_eq"])

    def test_eq_disabled_preserves_core_features(self):
        self.assertFalse(verify_ipa(self.package(eq=False), audio_eq=False)["audio_eq"])

    def test_full_feature_configuration(self):
        self.assertTrue(verify_ipa(self.package(ffmpeg=True, optional=True), ffmpeg=True, sponsorblock=True, ytuhd=True)["ffmpeg"])

    def test_missing_eq_code(self):
        with self.assertRaisesRegex(ValueError, "Embedded EQ code missing"):
            verify_ipa(self.package(eq=False))

    def test_missing_translation(self):
        with self.assertRaisesRegex(ValueError, "hu.lproj"):
            verify_ipa(self.package(skip=("hu.lproj",)))

    def test_old_eq_build_without_diagnostics_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "YTAEQDiagnosticsViewController"):
            verify_ipa(self.package(missing_marker=b"YTAEQDiagnosticsViewController"))

    def test_existing_pip_dependency_is_retained(self):
        with self.assertRaisesRegex(ValueError, "load YouPiP.dylib exactly once"):
            verify_ipa(self.package(reference_skip=("YouPiP.dylib",)))

    def test_existing_download_engine_is_retained(self):
        with self.assertRaisesRegex(ValueError, "uYou.dylib"):
            verify_ipa(self.package(skip=("/uYou.dylib",)))

    def test_duplicate_load_command(self):
        with self.assertRaisesRegex(ValueError, "exactly once"):
            verify_ipa(self.package(duplicate="uYouEnhanced.dylib"))

    def test_previously_injected_eq_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate audio hooks"):
            verify_ipa(self.package(standalone=True))

    def test_ffmpeg_requested_but_missing(self):
        with self.assertRaisesRegex(ValueError, "uYouMedia.bundle"):
            verify_ipa(self.package(), ffmpeg=True)

    def test_optional_sponsorblock_requested_but_missing(self):
        with self.assertRaisesRegex(ValueError, "iSponsorBlock.dylib"):
            verify_ipa(self.package(), sponsorblock=True)

    def test_eq_disabled_but_binary_contains_it(self):
        with self.assertRaisesRegex(ValueError, "EQ code is present"):
            verify_ipa(self.package(), audio_eq=False)

    def test_malformed_load_command(self):
        data = bytearray(macho(("uYouEnhanced.dylib",)))
        struct.pack_into("<I", data, 36, 4)
        with self.assertRaisesRegex(ValueError, "Invalid Mach-O load command"):
            dylib_references(data)


if __name__ == "__main__":
    unittest.main()
