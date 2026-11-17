"""Host-only parser/gate tests; mocked tool text is not device acceptance evidence."""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import call, patch


INSPECTORS = Path(__file__).resolve().parents[1] / "systemnnn_mobile"
ANDROID_LIBRARIES = (
    "libsystemnnn-mobile-link.so", "libengine_api.so", "libc++_shared.so",
)
EXPORTS = ("aether_systemnnn_mobile_link_probe", "aether_systemnnn_register_runtime")


def elf_output(needed=(), machine="AArch64", alignments=("0x4000", "0x4000"),
               undefined=()):
    """Representative readelf --wide -h -l -d -s output, never a real ELF."""
    lines = ["ELF Header:", f"  Machine:                           {machine}",
             "Program Headers:"]
    lines.extend(
        f"  LOAD 0x000000 0x0000000000000000 0x0000000000000000 0x001000 0x001000 R E {alignment}"
        for alignment in alignments
    )
    lines.extend(
        f" 0x0000000000000001 (NEEDED)             Shared library: [{name}]"
        for name in needed
    )
    lines.append("Symbol table '.dynsym' contains 3 entries:")
    for index, symbol in enumerate(EXPORTS, 1):
        section = "UND" if symbol in undefined else "12"
        lines.append(f" {index}: 0000000000001000 16 FUNC GLOBAL DEFAULT {section} {symbol}")
    return "\n".join(lines) + "\n"


class AndroidInspectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.package = Path(temporary.name) / "package"
        (self.package / "lib").mkdir(parents=True)
        for name in ANDROID_LIBRARIES:
            (self.package / "lib" / name).touch()
        self.readelf = "/mock/llvm-readelf"
        self.outputs = {
            ANDROID_LIBRARIES[0]: elf_output(("libengine_api.so", "libc++_shared.so", "liblog.so")),
            ANDROID_LIBRARIES[1]: elf_output(("libc++_shared.so", "libm.so")),
            ANDROID_LIBRARIES[2]: elf_output(("libc.so", "libdl.so")),
        }

    def inspect(self):
        script = INSPECTORS / "inspect_android.py"
        commands = {
            (self.readelf, "--wide", "-h", "-l", "-d", "-s",
             str(self.package / "lib" / name)): output
            for name, output in self.outputs.items()
        }
        stdout = io.StringIO()
        with patch.object(sys, "argv", [str(script), str(self.package), self.readelf]), \
                patch("subprocess.check_output",
                      side_effect=lambda command, **kwargs: commands[tuple(command)]) as mocked, \
                redirect_stdout(stdout):
            self.tool = mocked
            self.stdout = stdout
            runpy.run_path(str(script), run_name="__main__")
        return json.loads(stdout.getvalue())

    def assert_rejected(self, message):
        with self.assertRaises(SystemExit) as raised:
            self.inspect()
        self.assertIn(message, str(raised.exception))
        self.assertEqual(self.stdout.getvalue(), "")

    def test_aarch64_16k_defined_exports_and_dependency_closure(self):
        observations = self.inspect()
        self.assertEqual(observations, [
            {"binary": ANDROID_LIBRARIES[0], "machine": "AArch64",
             "load_alignments": [16384, 16384],
             "needed": ["libengine_api.so", "libc++_shared.so", "liblog.so"]},
            {"binary": ANDROID_LIBRARIES[1], "machine": "AArch64",
             "load_alignments": [16384, 16384], "needed": ["libc++_shared.so", "libm.so"]},
            {"binary": ANDROID_LIBRARIES[2], "machine": "AArch64",
             "load_alignments": [16384, 16384], "needed": ["libc.so", "libdl.so"]},
        ])
        self.assertEqual(self.tool.call_args_list, [
            call([self.readelf, "--wide", "-h", "-l", "-d", "-s",
                  str(self.package / "lib" / name)], text=True)
            for name in ANDROID_LIBRARIES
        ])

    def test_wrong_architecture_rejected_for_each_binary(self):
        for name in ANDROID_LIBRARIES:
            with self.subTest(binary=name):
                original = self.outputs[name]
                self.outputs[name] = elf_output(machine="Advanced Micro Devices X86-64")
                self.assert_rejected(f"{name}: expected AArch64")
                self.outputs[name] = original

    def test_missing_load_headers_rejected_for_each_binary(self):
        for name in ANDROID_LIBRARIES:
            with self.subTest(binary=name):
                original = self.outputs[name]
                self.outputs[name] = elf_output(alignments=())
                self.assert_rejected(f"{name}: LOAD alignment below 16 KiB: []")
                self.outputs[name] = original

    def test_one_4k_load_rejected_even_with_a_16k_load(self):
        for name in ANDROID_LIBRARIES:
            with self.subTest(binary=name):
                original = self.outputs[name]
                self.outputs[name] = elf_output(alignments=("0x4000", "0x1000"))
                self.assert_rejected(f"{name}: LOAD alignment below 16 KiB: [16384, 4096]")
                self.outputs[name] = original

    def test_unbundled_nonplatform_dependency_rejected_for_each_binary(self):
        for name in ANDROID_LIBRARIES:
            with self.subTest(binary=name):
                original = self.outputs[name]
                self.outputs[name] = elf_output(("libmissing.so",))
                self.assert_rejected(
                    f"{name}: unbundled non-platform dependencies: ['libmissing.so']")
                self.outputs[name] = original

    def test_undefined_required_exports_rejected(self):
        for symbol in EXPORTS:
            with self.subTest(symbol=symbol):
                self.outputs[ANDROID_LIBRARIES[0]] = elf_output(undefined=(symbol,))
                self.assert_rejected(f"missing defined symbol {symbol}")


class IOSInspectionTests(unittest.TestCase):
    def setUp(self):
        # No target file or Apple command-line tools are needed by these mocks.
        self.binary = Path("/mock/systemnnn-mobile-link")
        self.arch = "arm64\n"
        self.loads = ("Load command 1\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n"
                      " platform 2\n    minos 16.0\n      sdk 18.0\n")
        self.symbols = "".join(f"0000000100001000 T _{symbol}\n" for symbol in EXPORTS)
        self.libraries = (
            f"{self.binary}:\n"
            "\t/System/Library/Frameworks/Foundation.framework/Foundation (compatibility version 300.0.0, current version 300.0.0)\n"
            "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)\n"
        )

    def inspect(self):
        script = INSPECTORS / "inspect_ios.py"
        outputs = {
            ("lipo", "-archs", str(self.binary)): self.arch,
            ("otool", "-l", str(self.binary)): self.loads,
            ("nm", "-g", str(self.binary)): self.symbols,
            ("otool", "-L", str(self.binary)): self.libraries,
        }
        stdout = io.StringIO()
        with patch.object(sys, "argv", [str(script), str(self.binary)]), \
                patch("subprocess.check_output",
                      side_effect=lambda command, **kwargs: outputs[tuple(command)]) as mocked, \
                redirect_stdout(stdout):
            self.tool = mocked
            self.stdout = stdout
            runpy.run_path(str(script), run_name="__main__")
        return json.loads(stdout.getvalue())

    def assert_rejected(self, message):
        with self.assertRaises(SystemExit) as raised:
            self.inspect()
        self.assertIn(message, str(raised.exception))
        self.assertEqual(self.stdout.getvalue(), "")

    def test_arm64_iphoneos_platform2_minos16_and_system_libraries(self):
        self.assertEqual(self.inspect(), {
            "binary": self.binary.name, "architecture": "arm64", "platform": "iOS",
            "minimum_os": ["16.0"],
            "dynamic_libraries": [
                "/System/Library/Frameworks/Foundation.framework/Foundation",
                "/usr/lib/libSystem.B.dylib",
            ],
        })
        self.assertEqual(self.tool.call_args_list, [
            call(["lipo", "-archs", str(self.binary)], text=True),
            call(["otool", "-l", str(self.binary)], text=True),
            call(["nm", "-g", str(self.binary)], text=True),
            call(["otool", "-L", str(self.binary)], text=True),
        ])

    def test_simulator_platform7_rejected_even_for_arm64(self):
        self.loads = self.loads.replace("platform 2", "platform 7")
        self.assert_rejected("Expected iPhoneOS LC_BUILD_VERSION platform, observed ['7']")

    def test_wrong_architecture_rejected(self):
        for architecture in ("x86_64", "arm64 x86_64"):
            with self.subTest(architecture=architecture):
                self.arch = architecture + "\n"
                self.assert_rejected("Expected arm64 iPhoneOS binary")

    def test_undefined_required_exports_rejected(self):
        for symbol in EXPORTS:
            with self.subTest(symbol=symbol):
                self.symbols = "".join(
                    f"                 U _{name}\n" if name == symbol
                    else f"0000000100001000 T _{name}\n"
                    for name in EXPORTS
                )
                self.assert_rejected(f"Missing defined symbol _{symbol}")

    def test_non_system_dylibs_rejected(self):
        for library in ("@rpath/libengine_api.dylib", "/opt/local/lib/libforeign.dylib"):
            with self.subTest(library=library):
                self.libraries = (f"{self.binary}:\n"
                                  f"\t{library} (compatibility version 1.0.0, current version 1.0.0)\n")
                self.assert_rejected(
                    f"Unbundled non-system libraries in static iOS probe: [{library!r}]")


if __name__ == "__main__":
    unittest.main()
