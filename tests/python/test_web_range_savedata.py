from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
EMCC = shutil.which("emcc")
NODE = shutil.which("node")


@unittest.skipUnless(EMCC and NODE, "requires Emscripten and Node.js")
class WebRangeSaveTests(unittest.TestCase):
    def test_game_relative_saves_on_the_release_filesystem(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / "empty.c"
            source.write_text("int main(void) { return 0; }\n")
            module = folder / "game.cjs"
            subprocess.run([
                EMCC, str(source), "-O2", "-sMODULARIZE=1", "-sENVIRONMENT=node",
                "-sFORCE_FILESYSTEM=1", "-sEXPORTED_RUNTIME_METHODS=FS",
                "--post-js", str(ROOT / "scripts/web_export_range_fs.js"),
                "-o", str(module),
            ], check=True)
            subprocess.run([NODE, "-e", r"""
const assert = require('node:assert/strict');
require(process.argv[1])().then(runtime => {
    const fs = runtime.FS;
    const read = path => fs.readFile(path, {encoding: 'utf8'});
    const mount = (id, files) => runtime.aetherKiriMountRangeGame('/webgames/' + id, {}, {files});
    fs.mkdir('/userfs');
    fs.writeFile('/original', 'seed');
    const gameFile = {path: 'game.dat', size: 4, memfsPath: '/original'};
    const first = [gameFile, {path: 'SaveData/system.dat', size: 4, memfsPath: '/original'}];
    mount('first', first);
    mount('second', [gameFile]);
    assert.equal(read('/webgames/first/savedata/system.dat'), 'seed');
    fs.writeFile('/webgames/first/savedata/slot.tmp', 'checkpoint');
    fs.rename('/webgames/first/savedata/slot.tmp', '/webgames/first/savedata/slot');
    assert.equal(read('/webgames/first/SaveData/slot'), 'checkpoint');
    assert.throws(() => fs.stat('/webgames/first/missing'), {errno: 44});
    assert.throws(() => fs.writeFile('/webgames/first/game.dat', 'changed'));
    fs.writeFile('/webgames/first/savedata/system.dat', 'updated');
    mount('first', first);
    assert.equal(read('/webgames/first/savedata/system.dat'), 'updated');
    assert.equal(read('/userfs/aetherkiri/savedata/first/slot'), 'checkpoint');
    assert.equal(fs.analyzePath('/webgames/second/savedata/slot').exists, false);
    fs.writeFile('/webgames/second/savedata/slot', 'separate');
    assert.equal(read('/webgames/first/savedata/slot'), 'checkpoint');
    const incomplete = [gameFile,
        {path: 'savedata/old', size: 4, memfsPath: '/unavailable'},
        {path: 'savedata/good', size: 4, memfsPath: '/original'}];
    mount('third', incomplete);
    assert.equal(read('/webgames/third/savedata/good'), 'seed');
    fs.writeFile('/webgames/third/savedata/current', 'new');
    fs.writeFile('/unavailable', 'back');
    mount('third', incomplete);
    assert.equal(read('/webgames/third/savedata/old'), 'back');
    assert.equal(read('/webgames/third/savedata/current'), 'new');
}).catch(error => { console.error(error); process.exitCode = 1; });
""", str(module)], check=True)


if __name__ == "__main__":
    unittest.main()
