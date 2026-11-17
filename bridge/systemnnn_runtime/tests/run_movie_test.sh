#!/usr/bin/env bash
# Independent integration test; no provider/CMake changes required.
set -euo pipefail
movie_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
movie_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/systemnnn-movie.XXXXXXXX")
trap 'rm -rf -- "${movie_test_dir:?}"' EXIT
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=96x64:rate=10:duration=1 -f lavfi -i sine=frequency=997:sample_rate=48000:duration=1 -c:v mpeg4 -bf 2 -c:a aac -ac 1 "$movie_test_dir/av.mp4"
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=96x64:rate=10:duration=1 -c:v ffv1 "$movie_test_dir/silent.mkv"
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=96x64:rate=10:duration=1 -f lavfi -i sine=frequency=997:sample_rate=48000:duration=0.6 -af asetpts=PTS+0.3/TB -c:v ffv1 -c:a pcm_s16le "$movie_test_dir/delayed.mkv"
ffmpeg -nostdin -v error -y -i "$movie_test_dir/av.mp4" -map 0:a:0 -ar 44100 -ac 2 -f s16le "$movie_test_dir/reference.pcm"
ffmpeg -nostdin -v error -y -i "$movie_test_dir/av.mp4" -c copy -movflags +faststart "$movie_test_dir/faststart.mp4"
python3 - "$movie_test_dir" <<'PY'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
source = root / "faststart.mp4"
packets = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pos,size", "-of", "json", str(source)]))["packets"]
last = packets[-1]
(root / "corrupt.mkv").write_bytes(source.read_bytes()[:int(last["pos"]) + int(last["size"]) // 2])
PY
# macOS/vcpkg libiconv users may supply MOVIE_TEST_EXTRA_LIBS=-liconv.
read -r -a movie_ffmpeg_flags <<< "$(pkg-config --cflags --libs libavformat libavcodec libavutil libswscale libswresample)"
read -r -a movie_extra_flags <<< "${MOVIE_TEST_EXTRA_LIBS:-}"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror \
    -I"$movie_repo/bridge/systemnnn_runtime/src" \
    -I"$movie_repo/packages/SystemNNN-Emberfall/platform/render/include" \
    -I"$movie_repo/packages/SystemNNN-Emberfall/core/include" \
    "$movie_repo/bridge/systemnnn_runtime/tests/movie_test.cpp" \
    "$movie_repo/bridge/systemnnn_runtime/src/systemnnn_movie.cpp" \
    "$movie_repo/packages/SystemNNN-Emberfall/core/src/resource_path.cpp" \
    "${movie_ffmpeg_flags[@]}" "${movie_extra_flags[@]}" -o "$movie_test_dir/movie_test"
"$movie_test_dir/movie_test" "$movie_test_dir"
