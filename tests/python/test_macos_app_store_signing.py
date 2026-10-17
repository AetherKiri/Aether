import contextlib
import copy
import importlib.util
import io
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "macos_app_store_signing", REPO / ".github/scripts/macos-app-store-signing.py"
)
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)
SANDBOX = "com.apple.security.app-sandbox"
INHERIT = "com.apple.security.inherit"
JIT = "com.apple.security.cs.allow-jit"
FILE_ACCESS = "com.apple.security.files.user-selected.read-write"
HELPER_ENTITLEMENTS = {SANDBOX: True, INHERIT: True}


class AppleTools:
    """Model signing results, with explicit per-slice input/output fixtures."""

    def __init__(self):
        self.code = {}
        self.signatures = {}
        self.sign_calls = []
        self.displays = []
        self.display_errors = {}
        self.verify_errors = set()
        self.header_types = {}

    def add(self, path, kind="EXECUTE", architectures=("x86_64", "arm64"), entitlements=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"Mach-O fixture; Apple commands are mocked")
        self.code[path] = (kind, architectures)
        if entitlements is not None:
            for architecture in architectures:
                self.signatures[path, architecture] = copy.deepcopy(entitlements)
        return path

    def __call__(self, args, check=False, capture_output=False):
        args = [str(arg) for arg in args]
        path = Path(args[-1])
        stdout = b""
        stderr = b""
        status = 0
        if args[0] == "file":
            stdout = b"Mach-O universal binary" if path in self.code else b"POSIX shell script"
        elif args[0] == "lipo":
            stdout = " ".join(self.code[path][1]).encode()
        elif args[0] == "otool":
            kind, architectures = self.code[path]
            types = self.header_types.get(path, [kind] * len(architectures))
            # A universal otool -hv listing has one header per architecture.
            stdout = "\n".join(
                f"{path} (architecture {architecture}):\n"
                "Mach header\n"
                "      magic  cputype cpusubtype  caps    filetype ncmds sizeofcmds      flags\n"
                f"MH_MAGIC_64   ARM64        ALL  0x00     {filetype}    20       1736   NOUNDEFS"
                for architecture, filetype in zip(architectures, types)
            ).encode()
        elif args[0] == "codesign" and "--display" in args:
            architecture = args[args.index("--architecture") + 1]
            self.displays.append((path, architecture))
            if (path, architecture) in self.display_errors:
                status, stdout, stderr = self.display_errors[path, architecture]
            elif (path, architecture) not in self.signatures:
                status, stderr = 1, b"code object is not signed at all"
            else:
                stdout = plistlib.dumps(self.signatures[path, architecture])
        elif args[0] == "codesign" and "--verify" in args:
            if path in self.verify_errors:
                status, stderr = 1, b"invalid signature"
        elif args[0] == "codesign" and "--sign" in args:
            entitlements = None
            if "--entitlements" in args:
                entitlements = plistlib.loads(Path(args[args.index("--entitlements") + 1]).read_bytes())
            self.sign_calls.append((path, args, entitlements))
            if path in self.code:
                for architecture in self.code[path][1]:
                    if entitlements is not None:
                        self.signatures[path, architecture] = copy.deepcopy(entitlements)
                    elif ("--preserve-metadata=entitlements" not in args or
                          (self.code[path][0] != "EXECUTE" and "--force-library-entitlements" not in args)):
                        # macOS 15 drops library entitlements unless opted in,
                        # even with --preserve-metadata=entitlements.
                        self.signatures[path, architecture] = {}
                    else:
                        self.signatures.setdefault((path, architecture), {})
        else:
            raise AssertionError(f"Unexpected Apple command: {args}")
        result = subprocess.CompletedProcess(args, status, stdout, stderr)
        if check:
            result.check_returncode()
        return result


class MacAppStoreSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aether signing tests ")
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Aether App.app"
        self.frameworks = self.app / "Contents/Frameworks"
        self.frameworks.mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Aether"}))
        self.tools = AppleTools()
        self.main = self.tools.add(self.app / "Contents/MacOS/Aether", entitlements={SANDBOX: True, FILE_ACCESS: True})
        self.helper = self.tools.add(self.frameworks / "renpy-runtime/mac-universal/python")
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(SIGNING.subprocess, "run", side_effect=self.tools).start()

    def sign(self):
        SIGNING.sign_nested(self.app, "arm64", "Apple Distribution: Test", "keychain with spaces")

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            SIGNING.verify(self.app, "arm64")

    def test_signs_all_renpy_helpers_with_inheritance_and_preserves_existing_capabilities(self):
        helpers = [self.helper] + [
            self.tools.add(self.helper.with_name(name), entitlements={JIT: True})
            for name in ("pythonw", "renpy", "zsync", "zsyncmake")
        ]
        library = self.tools.add(self.frameworks / "library with spaces.dylib", "DYLIB", entitlements={JIT: True})
        library.chmod(0o755)
        extension = self.tools.add(self.frameworks / "extension.so", "BUNDLE", entitlements={})
        self.helper.chmod(0o644)  # MH_EXECUTE still needs entitlements without +x.
        script = self.frameworks / "launcher script"
        script.write_text("#!/bin/sh\nexec python\n")
        script.chmod(0o755)
        (self.frameworks / "python alias").symlink_to(self.helper)
        (self.app / "Contents/Resources").mkdir()
        (self.app / "Contents/Resources/runtime alias").symlink_to(self.helper.parent, target_is_directory=True)
        outside = self.tools.add(Path(self.temporary.name) / "outside/executable")
        (self.frameworks / "outside alias").symlink_to(outside.parent, target_is_directory=True)
        self.sign()
        calls = {path: (args, entitlements) for path, args, entitlements in self.tools.sign_calls}
        self.assertEqual(set(calls), {*helpers, library, extension})
        self.assertEqual(len(calls), len(self.tools.sign_calls))
        for helper in helpers:
            args, entitlements = calls[helper]
            expected = HELPER_ENTITLEMENTS if helper == self.helper else {**HELPER_ENTITLEMENTS, JIT: True}
            self.assertEqual(entitlements, expected)
            self.assertNotIn(FILE_ACCESS, entitlements)
            self.assertNotIn("com.apple.application-identifier", entitlements)
            self.assertIn("--timestamp", args)
            self.assertNotIn("--deep", args)
        for path in (library, extension):
            args, entitlements = calls[path]
            self.assertEqual(entitlements, {JIT: True} if path == library else None)
            self.assertEqual("--force-library-entitlements" in args, path == library)
        self.assertEqual(self.tools.signatures[library, "arm64"], {JIT: True})
        self.verify()
        for executable in [self.main, *helpers]:
            for architecture in ("x86_64", "arm64"):
                self.assertIn((executable, architecture), self.tools.displays)

    def test_seals_frameworks_after_their_nested_code(self):
        framework = self.frameworks / "Outer.framework"
        inner = framework / "Frameworks/Inner.framework"
        binaries = [
            self.tools.add(framework / "Versions/A/Outer", "DYLIB", entitlements={}),
            self.tools.add(inner / "Inner", "DYLIB", entitlements={}),
        ]
        (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
        (framework / "Outer").symlink_to("Versions/Current/Outer")
        for bundle, executable in [(framework, "Outer"), (inner, "Inner")]:
            (bundle / "Resources").mkdir()
            (bundle / "Resources/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": executable}))
        self.sign()
        signed = [path for path, _, _ in self.tools.sign_calls]
        self.assertLess(signed.index(inner), signed.index(framework))
        for binary in binaries:
            self.assertLess(signed.index(binary), signed.index(inner))

    def test_header_like_words_and_newlines_in_paths_are_not_parsed_as_headers(self):
        helper = self.tools.add(self.frameworks / "a filetype word\nhelper")
        self.sign()
        self.verify()
        self.assertEqual(self.tools.signatures[helper, "arm64"], HELPER_ENTITLEMENTS)

    def test_missing_target_architecture_fails_before_signing(self):
        self.tools.code[self.helper] = ("EXECUTE", ("x86_64",))
        with self.assertRaisesRegex(ValueError, "missing arm64"):
            self.sign()
        self.assertFalse(self.tools.sign_calls)

    def test_fails_if_signer_drops_existing_library_entitlements(self):
        library = self.tools.add(self.frameworks / "library.dylib", "DYLIB", entitlements={JIT: True})
        real_run = SIGNING.run

        def dropping_signer(*args):
            result = real_run(*args)
            if "--sign" in args and Path(args[-1]) == library:
                self.tools.signatures[library, "x86_64"] = {}
            return result

        with mock.patch.object(SIGNING, "run", side_effect=dropping_signer):
            with self.assertRaisesRegex(ValueError, "Library entitlements changed.*x86_64"):
                self.sign()

    def test_inconsistent_universal_file_types_fail_before_signing(self):
        self.tools.header_types[self.helper] = ["DYLIB", "EXECUTE"]
        with self.assertRaisesRegex(ValueError, "Inconsistent Mach-O"):
            self.sign()
        self.assertFalse(self.tools.sign_calls)

    def test_architecture_specific_entitlements_are_not_silently_overwritten(self):
        self.tools.signatures[self.helper, "x86_64"] = {JIT: True}
        self.tools.signatures[self.helper, "arm64"] = {}
        with self.assertRaisesRegex(ValueError, "differ across architectures"):
            self.sign()
        self.assertFalse(self.tools.sign_calls)

    def test_architecture_specific_library_entitlements_fail_before_signing(self):
        library = self.tools.add(self.frameworks / "library.dylib", "DYLIB", entitlements={})
        self.tools.signatures[library, "arm64"] = {JIT: True}
        with self.assertRaisesRegex(ValueError, "differ across architectures"):
            self.sign()
        self.assertFalse(self.tools.sign_calls)

    def test_incompatible_helper_permissions_fail_instead_of_being_lost(self):
        for architecture in ("arm64", "x86_64"):
            self.tools.signatures[self.helper, architecture] = {FILE_ACCESS: True}
        with self.assertRaisesRegex(ValueError, "incompatible with inheritance"):
            self.sign()
        self.assertFalse(self.tools.sign_calls)

    def test_display_errors_and_malformed_entitlements_are_not_treated_as_unsigned(self):
        for result, error in [
            ((1, b"", b"invalid signature"), subprocess.CalledProcessError),
            ((0, b"not a plist", b""), ValueError),
        ]:
            with self.subTest(result=result):
                self.tools.display_errors[self.helper, "x86_64"] = result
                with self.assertRaises(error):
                    self.sign()
                self.assertFalse(self.tools.sign_calls)

    def test_checks_sandbox_and_inheritance_as_booleans_on_every_slice(self):
        self.sign()
        for path, key in [(self.main, SANDBOX), (self.helper, SANDBOX), (self.helper, INHERIT)]:
            for value in (None, False, "true", 1):
                with self.subTest(path=path, key=key, value=value):
                    original = self.tools.signatures[path, "x86_64"]
                    self.tools.signatures[path, "x86_64"] = {**original, key: value}
                    if value is None:
                        del self.tools.signatures[path, "x86_64"][key]
                    try:
                        with self.assertRaisesRegex(ValueError, "missing Boolean"):
                            self.verify()
                    finally:
                        self.tools.signatures[path, "x86_64"] = original

    def test_main_cannot_inherit_and_helpers_cannot_grow_sandbox_permissions(self):
        self.sign()
        for path, key in [(self.main, INHERIT), (self.helper, FILE_ACCESS)]:
            with self.subTest(path=path):
                original = self.tools.signatures[path, "arm64"]
                self.tools.signatures[path, "arm64"] = {**original, key: True}
                with self.assertRaises(ValueError):
                    self.verify()
                self.tools.signatures[path, "arm64"] = original

    def test_additional_executable_outside_frameworks_is_not_missed(self):
        self.sign()
        self.tools.add(self.app / "Contents/Resources/unexpected helper", entitlements={})
        with self.assertRaisesRegex(ValueError, "missing Boolean App Sandbox"):
            self.verify()

    def test_invalid_or_unsigned_helper_signature_fails_validation(self):
        self.sign()
        self.tools.verify_errors.add(self.helper)
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()
        self.tools.verify_errors.clear()
        del self.tools.signatures[self.helper, "arm64"]
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_missing_main_executable_fails_validation(self):
        self.sign()
        self.main.unlink()
        with self.assertRaisesRegex(ValueError, "Main application is not a physical Mach-O"):
            self.verify()


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "real Mach-O signing requires macOS/Xcode")
class MacAppStoreAdHocSigningTests(unittest.TestCase):
    def command(self, *args):
        result = subprocess.run([str(arg) for arg in args], capture_output=True)
        self.assertEqual(result.returncode, 0, f"{args}\n{result.stdout.decode(errors='replace')}\n{result.stderr.decode(errors='replace')}")
        return result

    def test_real_universal_helpers_libraries_and_resource_symlinks(self):
        with tempfile.TemporaryDirectory(prefix="aether real signing ") as directory:
            root = Path(directory)
            app = root / "Aether App.app"
            frameworks = app / "Contents/Frameworks"
            frameworks.mkdir(parents=True)
            main = app / "Contents/MacOS/Aether"
            main.parent.mkdir()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Aether", "CFBundleIdentifier": "test.aether.signing",
                "CFBundlePackageType": "APPL",
            }))
            source = root / "fixture.c"
            source.write_text("int main(void) { return 0; }\n")
            helper = frameworks / "renpy runtime/python"
            helper.parent.mkdir()
            self.command("clang", "-arch", "x86_64", "-arch", "arm64", "-mmacosx-version-min=11.0",
                         source, "-o", helper)
            shutil.copy2(helper, main)
            for flag, filename in [("-dynamiclib", "library.dylib"), ("-bundle", "extension.so")]:
                self.command("clang", "-arch", "x86_64", "-arch", "arm64", "-mmacosx-version-min=11.0",
                             flag, source, "-o", frameworks / filename)
            existing = root / "existing.plist"
            existing.write_bytes(plistlib.dumps({JIT: True}))
            self.command("codesign", "--force", "--sign", "-", "--entitlements", existing, helper)
            library = frameworks / "library.dylib"
            # macOS 15 requires this opt-in to embed initial library
            # entitlements. Re-signing must retain these existing keys too.
            self.command("codesign", "--force", "--sign", "-", "--force-library-entitlements",
                         "--entitlements", existing, library)
            for architecture in ("x86_64", "arm64"):
                self.assertEqual(SIGNING.read_entitlements(library, architecture), {JIT: True})
            framework = frameworks / "Library.framework"
            version = framework / "Versions/A"
            (version / "Resources").mkdir(parents=True)
            framework_library = version / "Library"
            shutil.copy2(library, framework_library)
            (version / "Resources/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Library", "CFBundleIdentifier": "test.aether.signing.library",
                "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            }))
            (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
            (framework / "Library").symlink_to("Versions/Current/Library")
            (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
            (app / "Contents/Resources").mkdir()
            (app / "Contents/Resources/runtime").symlink_to("../Frameworks/renpy runtime", target_is_directory=True)
            (helper.parent / "python alias").symlink_to("python")
            script = app / "Contents/Resources/script"
            script.write_text("#!/bin/sh\nexit 0\n")
            script.chmod(0o755)
            real_run = SIGNING.run

            def ad_hoc_run(*args):
                # Exercise the production path with certificate-free ad-hoc
                # signatures. Distribution timestamps/keychains need secrets.
                args = list(args)
                if "--sign" in args:
                    index = args.index("--keychain")
                    del args[index:index + 2]
                    args[args.index("--timestamp")] = "--timestamp=none"
                return real_run(*args)

            with mock.patch.object(SIGNING, "run", side_effect=ad_hoc_run):
                SIGNING.sign_nested(app, "arm64", "-", "unused")
            for architecture in ("x86_64", "arm64"):
                for binary in (library, framework_library):
                    self.assertEqual(SIGNING.read_entitlements(binary, architecture), {JIT: True})
            main_entitlements = root / "main.plist"
            main_entitlements.write_bytes(plistlib.dumps({SANDBOX: True, FILE_ACCESS: True}))
            self.command("codesign", "--force", "--sign", "-", "--entitlements", main_entitlements, app)
            self.command("codesign", "--verify", "--deep", "--strict", app)
            SIGNING.verify(app, "arm64")
            for architecture in ("x86_64", "arm64"):
                self.assertEqual(SIGNING.read_entitlements(helper, architecture), {**HELPER_ENTITLEMENTS, JIT: True})
                self.assertEqual(SIGNING.read_entitlements(main, architecture), {SANDBOX: True, FILE_ACCESS: True})
                self.assertEqual(SIGNING.read_entitlements(library, architecture), {JIT: True})
                self.assertEqual(SIGNING.read_entitlements(framework_library, architecture), {JIT: True})
            # A valid signature without sandbox in just one slice must fail
            # locally even though the target arm64 slice remains correct.
            x86_helper = root / "x86-helper"
            self.command("lipo", helper, "-thin", "x86_64", "-output", x86_helper)
            self.command("codesign", "--force", "--sign", "-", x86_helper)
            self.command("lipo", helper, "-replace", "x86_64", x86_helper, "-output", helper)
            with self.assertRaisesRegex(ValueError, "missing Boolean App Sandbox"):
                SIGNING.verify(app, "arm64")


if __name__ == "__main__":
    unittest.main()
