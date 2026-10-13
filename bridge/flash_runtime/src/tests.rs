use super::*;
use ::swf;

#[derive(Clone, Default)]
struct TestLog(Arc<Mutex<Vec<String>>>);

impl LogBackend for TestLog {
    fn avm_trace(&self, message: &str) {
        self.0.lock().unwrap().push(message.to_owned());
    }
    fn avm_warning(&self, _message: &str) {}
}

struct Movie {
    handle: *mut Flash,
    log: TestLog,
    pixels: Vec<u8>,
}

impl Movie {
    fn open(fixture: &str, storage: &Path) -> Self {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../packages/ruffle/tests/tests/swfs")
            .join(fixture)
            .join("test.swf");
        Self::open_path(&path, storage)
    }

    fn open_path(path: &Path, storage: &Path) -> Self {
        let log = TestLog::default();
        let flash = Flash::open_with_log(path, storage, log.clone()).unwrap();
        let pixels = vec![0; flash.width as usize * flash.height as usize * 4];
        let mut movie = Self {
            handle: Box::into_raw(Box::new(flash)),
            log,
            pixels,
        };
        movie.tick();
        movie
    }

    fn tick(&mut self) {
        self.tick_ms(100.0);
    }

    fn tick_ms(&mut self, milliseconds: f64) {
        let frames = (milliseconds * 44.1) as usize;
        let mut audio = vec![0.0f32; frames * 2];
        assert!(unsafe { aether_flash_audio(self.handle, audio.as_mut_ptr(), frames) });
        assert!(
            unsafe {
                aether_flash_tick(
                    self.handle,
                    milliseconds,
                    self.pixels.as_mut_ptr(),
                    self.pixels.len(),
                )
            },
            "{}",
            unsafe { CStr::from_ptr(aether_flash_error()).to_string_lossy() }
        );
    }

    fn input(&mut self, kind: u32, x: f64, y: f64, code: u32, unicode: u32) {
        assert!(unsafe { aether_flash_input(self.handle, kind, x, y, code, unicode) });
    }

    fn traced(&self, text: &str) -> bool {
        self.log
            .0
            .lock()
            .unwrap()
            .iter()
            .any(|line| line.contains(text))
    }
}

impl Drop for Movie {
    fn drop(&mut self) {
        unsafe { aether_flash_close(self.handle) };
    }
}

// Uses Ruffle's pinned fixtures without copying upstream assets into this repo.
// No window is needed, but an actual Metal/Vulkan/DX12 adapter is required.
#[test]
#[ignore = "requires a native GPU adapter; run cargo test -- --ignored --nocapture"]
fn native_playback_input_audio_and_storage() {
    let storage = std::env::temp_dir().join(format!(
        "aether-flash-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));

    {
        let mut movie = Movie::open("avm1/button_goto", &storage);
        let original = movie.pixels.clone();
        assert!(
            original
                .chunks_exact(4)
                .any(|pixel| pixel != &original[..4])
        );
        movie.input(3, 160.0, 160.0, 0, 0);
        movie.tick();
        movie.tick();
        assert!(
            movie.traced("rollOver"),
            "Mouse motion must reach the SWF button"
        );
        movie.input(4, 160.0, 160.0, 0, 0);
        movie.tick();
        movie.input(3, 0.0, 0.0, 0, 0);
        movie.tick();
        assert!(
            movie.traced("dragOut"),
            "Mouse down must establish a pressed button"
        );
        movie.input(5, 0.0, 0.0, 0, 0);
        println!("FLASH_MOUSE_RENDER_OK");
    }
    {
        let mut movie = Movie::open("from_shumway/timeline/timeline_loop", &storage);
        let original = movie.pixels.clone();
        let mut changed = false;
        for _ in 0..20 {
            movie.tick_ms(1000.0 / 60.0);
            changed |= movie.pixels != original;
        }
        assert!(
            changed,
            "Timeline playback must produce changing rendered frames: {:?}",
            movie.log.0.lock().unwrap()
        );
        println!("FLASH_ANIMATION_OK");
    }
    {
        let mut movie = Movie::open("avm1/button_keypress_vs_press", &storage);
        for (code, unicode) in [(32, 32), (13, 0)] {
            movie.input(1, 0.0, 0.0, code, unicode);
            movie.input(2, 0.0, 0.0, code, 0);
        }
        movie.tick();
        assert!(movie.traced("Space pressed") && movie.traced("Enter pressed"));
        assert!(
            movie.traced("button.onKeyUp: 32"),
            "Key releases must reach the movie"
        );
        unsafe { aether_flash_pause(movie.handle, true) };
        assert!(
            !unsafe { &*movie.handle }
                .player
                .lock()
                .unwrap()
                .is_playing()
        );
        unsafe { aether_flash_pause(movie.handle, false) };
        assert!(
            unsafe { &*movie.handle }
                .player
                .lock()
                .unwrap()
                .is_playing()
        );
        println!("FLASH_AVM1_KEYS_PAUSE_OK");
    }
    {
        let movie = Movie::open("avm2/hello_world", &storage);
        assert!(movie.traced("Hello world!"), "ActionScript 3 must execute");
        println!("FLASH_AVM2_OK");
    }
    {
        // Start Ruffle's MP3 fixture at the beginning, rather than using its
        // sound_play test which deliberately seeks into trailing silence.
        std::fs::create_dir_all(&storage).unwrap();
        let mp3 = std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../packages/ruffle/tests/tests/swfs/avm2/sound_play/noise.mp3"),
        )
        .unwrap();
        let mut data = vec![0, 0]; // SWF MP3 latency/seek prefix.
        data.extend(mp3);
        let audio_path = storage.join("audio.swf");
        let mut header = swf::Header::default_with_swf_version(7);
        header.frame_rate = swf::Fixed8::from_f32(12.0);
        header.num_frames = 1;
        swf::write_swf(
            &header,
            &[
                swf::Tag::DefineSound(swf::Sound {
                    id: 1,
                    num_samples: 46080,
                    format: swf::SoundFormat {
                        compression: swf::AudioCompression::Mp3,
                        sample_rate: 44100,
                        is_stereo: false,
                        is_16_bit: true,
                    },
                    data: &data,
                }),
                swf::Tag::StartSound(swf::StartSound {
                    id: 1,
                    sound_info: Box::new(swf::SoundInfo {
                        event: swf::SoundEvent::Start,
                        in_sample: None,
                        out_sample: None,
                        num_loops: 1,
                        envelope: None,
                    }),
                }),
                swf::Tag::ShowFrame,
                swf::Tag::End,
            ],
            std::fs::File::create(&audio_path).unwrap(),
        )
        .unwrap();
        let mut movie = Movie::open_path(&audio_path, &storage);
        let mut samples = vec![0.0f32; 4096];
        let mut audible = false;
        for _ in 0..10 {
            assert!(unsafe { aether_flash_audio(movie.handle, samples.as_mut_ptr(), 2048) });
            audible |= samples.iter().any(|value| value.abs() > 0.0001);
            movie.tick_ms(1000.0 / 60.0);
        }
        assert!(
            audible,
            "The embedded sound must produce stereo audio samples: {:?}",
            movie.log.0.lock().unwrap()
        );
        println!("FLASH_AUDIO_OK");
    }
    {
        let movie = Movie::open("avm1/shared_object", &storage);
        assert!(movie.traced("No data found. Initializing..."));
    }
    assert!(std::fs::read_dir(&storage).unwrap().any(|entry| {
        entry
            .unwrap()
            .path()
            .extension()
            .is_some_and(|ext| ext == "sol")
    }));
    {
        let movie = Movie::open("avm1/shared_object", &storage);
        assert!(
            movie.traced("saved: true") && movie.traced("str: hello"),
            "SharedObject must survive closing and reopening the player"
        );
        println!("FLASH_STORAGE_OK");
    }
    std::fs::remove_dir_all(storage).unwrap();
}
