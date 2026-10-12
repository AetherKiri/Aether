//! Ruffle host: Godot owns presentation, audio output and all input surfaces.
use ruffle_core::backend::audio::{
    AudioBackend, AudioMixer, AudioMixerProxy, DecodeError, RegisterError, SoundHandle,
    SoundInstanceHandle, SoundStreamInfo, SoundTransform, swf,
};
use ruffle_core::backend::log::{LogBackend, NullLogBackend};
use ruffle_core::backend::navigator::{NullExecutor, NullNavigatorBackend};
use ruffle_core::backend::storage::StorageBackend;
use ruffle_core::backend::ui::FontDefinition;
use ruffle_core::events::{
    KeyDescriptor, KeyLocation, LogicalKey, MouseButton, MouseWheelDelta, NamedKey, PhysicalKey,
    PlayerEvent, TextControlCode,
};
use ruffle_core::font::{DefaultFont, FontFileData};
use ruffle_core::{FloatDuration, Player, PlayerBuilder, impl_audio_mixer_backend};
use ruffle_render_wgpu::{backend::WgpuRenderBackend, target::TextureTarget, wgpu};
use ruffle_video_software::backend::SoftwareVideoBackend;
use sha2::{Digest, Sha256};
use std::{
    any::Any,
    cell::RefCell,
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    path::{Path, PathBuf},
    ptr,
    sync::{Arc, Mutex},
    time::Duration,
};

thread_local! { static ERROR: RefCell<CString> = RefCell::new(CString::default()); }
fn fail(message: impl ToString) {
    ERROR.with(|error| {
        *error.borrow_mut() = CString::new(message.to_string().replace('\0', "")).unwrap()
    });
}
fn guarded<T: Default>(f: impl FnOnce() -> Result<T, String>) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            fail(message);
            T::default()
        }
        Err(_) => {
            fail("Ruffle stopped after an internal error");
            T::default()
        }
    }
}
struct Audio {
    mixer: AudioMixer,
}
impl AudioBackend for Audio {
    impl_audio_mixer_backend!(mixer);
    fn play(&mut self) {}
    fn pause(&mut self) {}
    fn set_frame_rate(&mut self, _: f64) {}
}
struct Storage(PathBuf);
impl Storage {
    fn path(&self, name: &str) -> PathBuf {
        self.0
            .join(format!("{:x}.sol", Sha256::digest(name.as_bytes())))
    }
}
impl StorageBackend for Storage {
    fn get(&self, name: &str) -> Option<Vec<u8>> {
        std::fs::read(self.path(name)).ok()
    }
    fn put(&mut self, name: &str, value: &[u8]) -> bool {
        if std::fs::create_dir_all(&self.0).is_err() {
            return false;
        }
        let path = self.path(name);
        let pending = path.with_extension("tmp");
        std::fs::write(&pending, value)
            .and_then(|_| std::fs::rename(pending, path))
            .is_ok()
    }
    fn remove_key(&mut self, name: &str) {
        let _ = std::fs::remove_file(self.path(name));
    }
}
pub struct Flash {
    player: Arc<Mutex<Player>>,
    executor: NullExecutor,
    audio: AudioMixerProxy,
    width: u32,
    height: u32,
}
impl Flash {
    fn open(path: &Path, storage: &Path) -> Result<Self, String> {
        Self::open_with_log(path, storage, NullLogBackend::new())
    }

    fn open_with_log(
        path: &Path,
        storage: &Path,
        log: impl 'static + LogBackend,
    ) -> Result<Self, String> {
        let movie =
            ruffle_core::tag_utils::movie_from_path(path, None).map_err(|e| e.to_string())?;
        let w = movie.width().to_pixels().max(1.0);
        let h = movie.height().to_pixels().max(1.0);
        let scale = (1920.0 / w).min(1080.0 / h).min(1.0);
        let width = (w * scale).ceil() as u32;
        let height = (h * scale).ceil() as u32;
        let renderer = WgpuRenderBackend::for_offscreen(
            (width, height),
            wgpu::Backends::PRIMARY,
            wgpu::PowerPreference::LowPower,
        )
        .map_err(|e| e.to_string())?;
        let executor = NullExecutor::new();
        let navigator = NullNavigatorBackend::with_base_path(
            path.parent().unwrap_or(Path::new(".")),
            &executor,
        )
        .map_err(|e| e.to_string())?;
        let mixer = AudioMixer::new(2, 44100);
        let audio = mixer.proxy();
        let player = PlayerBuilder::new()
            .with_renderer(renderer)
            .with_audio(Audio { mixer })
            .with_log(log)
            .with_video(SoftwareVideoBackend::new())
            .with_navigator(navigator)
            .with_storage(Box::new(Storage(storage.to_path_buf())))
            .with_movie(movie)
            .with_default_font(true)
            .with_autoplay(true)
            .with_viewport_dimensions(width, height, 1.0)
            .with_max_execution_duration(Duration::from_secs(2))
            .build();
        Ok(Self {
            player,
            executor,
            audio,
            width,
            height,
        })
    }
}

#[cfg(test)]
mod tests;

#[unsafe(no_mangle)]
pub extern "C" fn aether_flash_error() -> *const c_char {
    ERROR.with(|e| e.borrow().as_ptr())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_open(
    path: *const c_char,
    storage: *const c_char,
) -> *mut Flash {
    guarded(|| {
        if path.is_null() || storage.is_null() {
            return Err("Missing Flash path".into());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|e| e.to_string())?;
        let storage = unsafe { CStr::from_ptr(storage) }
            .to_str()
            .map_err(|e| e.to_string())?;
        Ok(Box::into_raw(Box::new(Flash::open(
            Path::new(path),
            Path::new(storage),
        )?)))
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_close(handle: *mut Flash) {
    if handle.is_null() {
        return;
    }
    guarded(|| {
        let flash = unsafe { Box::from_raw(handle) };
        if let Ok(mut player) = flash.player.lock() {
            player.flush_shared_objects();
        }
        Ok(())
    });
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_width(handle: *const Flash) -> u32 {
    unsafe { handle.as_ref() }.map_or(0, |p| p.width)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_height(handle: *const Flash) -> u32 {
    unsafe { handle.as_ref() }.map_or(0, |p| p.height)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_font(handle: *mut Flash, path: *const c_char) -> bool {
    guarded(|| {
        let flash = unsafe { handle.as_mut() }.ok_or("Missing Flash player")?;
        if path.is_null() {
            return Err("Missing Flash font".into());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|e| e.to_string())?;
        let data = std::fs::read(path).map_err(|e| e.to_string())?;
        let mut player = flash.player.lock().map_err(|e| e.to_string())?;
        player.register_device_font(FontDefinition::FontFile {
            name: "Aether CJK".into(),
            is_bold: false,
            is_italic: false,
            data: FontFileData::new(data),
            index: 0,
        });
        for font in [
            DefaultFont::Sans,
            DefaultFont::Serif,
            DefaultFont::Typewriter,
            DefaultFont::JapaneseGothic,
            DefaultFont::JapaneseGothicMono,
            DefaultFont::JapaneseMincho,
        ] {
            player.set_default_font(font, vec!["Aether CJK".into(), "Noto Sans".into()]);
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_tick(
    handle: *mut Flash,
    milliseconds: f64,
    pixels: *mut u8,
    capacity: usize,
) -> bool {
    guarded(|| {
        let flash = unsafe { handle.as_mut() }.ok_or("Missing Flash player")?;
        if pixels.is_null() || capacity < flash.width as usize * flash.height as usize * 4 {
            return Err("Invalid Flash frame buffer".into());
        }
        flash.executor.run();
        let mut player = flash.player.lock().map_err(|e| e.to_string())?;
        player.tick(FloatDuration::from_millis(milliseconds.clamp(0.0, 100.0)));
        player.render();
        let renderer =
            <dyn Any>::downcast_ref::<WgpuRenderBackend<TextureTarget>>(player.renderer())
                .ok_or("Flash renderer unavailable")?;
        let frame = renderer.capture_frame().ok_or("Flash frame unavailable")?;
        unsafe {
            ptr::copy_nonoverlapping(frame.as_ptr(), pixels, frame.len());
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_audio(
    handle: *const Flash,
    samples: *mut f32,
    frames: usize,
) -> bool {
    guarded(|| {
        let flash = unsafe { handle.as_ref() }.ok_or("Missing Flash player")?;
        if samples.is_null() || frames > 44100 {
            return Err("Invalid Flash audio buffer".into());
        }
        flash
            .audio
            .mix(unsafe { std::slice::from_raw_parts_mut(samples, frames * 2) });
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_pause(handle: *mut Flash, paused: bool) {
    guarded(|| {
        let flash = unsafe { handle.as_mut() }.ok_or("Missing Flash player")?;
        let mut player = flash.player.lock().map_err(|e| e.to_string())?;
        if paused {
            player.handle_event(PlayerEvent::FocusLost);
            player.flush_shared_objects();
        } else {
            player.handle_event(PlayerEvent::FocusGained);
        }
        player.set_is_playing(!paused);
        Ok(())
    });
}
fn key(code: u32, unicode: u32) -> KeyDescriptor {
    use NamedKey as N;
    use PhysicalKey as P;
    let named = match code {
        8 => Some((P::Backspace, N::Backspace)),
        9 => Some((P::Tab, N::Tab)),
        13 => Some((P::Enter, N::Enter)),
        15 => Some((P::SuperLeft, N::Super)),
        16 => Some((P::ShiftLeft, N::Shift)),
        17 => Some((P::ControlLeft, N::Control)),
        18 => Some((P::AltLeft, N::Alt)),
        19 => Some((P::Pause, N::Pause)),
        20 => Some((P::CapsLock, N::CapsLock)),
        27 => Some((P::Escape, N::Escape)),
        33 => Some((P::PageUp, N::PageUp)),
        34 => Some((P::PageDown, N::PageDown)),
        35 => Some((P::End, N::End)),
        36 => Some((P::Home, N::Home)),
        37 => Some((P::ArrowLeft, N::ArrowLeft)),
        38 => Some((P::ArrowUp, N::ArrowUp)),
        39 => Some((P::ArrowRight, N::ArrowRight)),
        40 => Some((P::ArrowDown, N::ArrowDown)),
        45 => Some((P::Insert, N::Insert)),
        46 => Some((P::Delete, N::Delete)),
        _ => None,
    };
    let (physical_key, logical_key) = if let Some((p, n)) = named {
        (p, LogicalKey::Named(n))
    } else {
        let letters = [
            P::KeyA,
            P::KeyB,
            P::KeyC,
            P::KeyD,
            P::KeyE,
            P::KeyF,
            P::KeyG,
            P::KeyH,
            P::KeyI,
            P::KeyJ,
            P::KeyK,
            P::KeyL,
            P::KeyM,
            P::KeyN,
            P::KeyO,
            P::KeyP,
            P::KeyQ,
            P::KeyR,
            P::KeyS,
            P::KeyT,
            P::KeyU,
            P::KeyV,
            P::KeyW,
            P::KeyX,
            P::KeyY,
            P::KeyZ,
        ];
        let digits = [
            P::Digit0,
            P::Digit1,
            P::Digit2,
            P::Digit3,
            P::Digit4,
            P::Digit5,
            P::Digit6,
            P::Digit7,
            P::Digit8,
            P::Digit9,
        ];
        let functions = [
            (P::F1, N::F1),
            (P::F2, N::F2),
            (P::F3, N::F3),
            (P::F4, N::F4),
            (P::F5, N::F5),
            (P::F6, N::F6),
            (P::F7, N::F7),
            (P::F8, N::F8),
            (P::F9, N::F9),
            (P::F10, N::F10),
            (P::F11, N::F11),
            (P::F12, N::F12),
            (P::F13, N::F13),
            (P::F14, N::F14),
            (P::F15, N::F15),
            (P::F16, N::F16),
            (P::F17, N::F17),
            (P::F18, N::F18),
            (P::F19, N::F19),
            (P::F20, N::F20),
            (P::F21, N::F21),
            (P::F22, N::F22),
            (P::F23, N::F23),
            (P::F24, N::F24),
        ];
        if (112..=135).contains(&code) {
            let (physical_key, named) = functions[(code - 112) as usize];
            return KeyDescriptor {
                physical_key,
                logical_key: LogicalKey::Named(named),
                key_location: KeyLocation::Standard,
            };
        }
        let p = match code {
            65..=90 => letters[(code - 65) as usize],
            48..=57 => digits[(code - 48) as usize],
            32 => P::Space,
            186 => P::Semicolon,
            187 => P::Equal,
            188 => P::Comma,
            189 => P::Minus,
            190 => P::Period,
            191 => P::Slash,
            192 => P::Backquote,
            219 => P::BracketLeft,
            220 => P::Backslash,
            221 => P::BracketRight,
            222 => P::Quote,
            _ => P::Unknown,
        };
        let ch = char::from_u32(if unicode != 0 { unicode } else { code }).unwrap_or('\0');
        (p, LogicalKey::Character(ch))
    };
    KeyDescriptor {
        physical_key,
        logical_key,
        key_location: KeyLocation::Standard,
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aether_flash_input(
    handle: *mut Flash,
    kind: u32,
    x: f64,
    y: f64,
    code: u32,
    unicode: u32,
) -> bool {
    guarded(|| {
        let flash = unsafe { handle.as_mut() }.ok_or("Missing Flash player")?;
        let button = match code {
            1 => MouseButton::Right,
            2 => MouseButton::Middle,
            _ => MouseButton::Left,
        };
        let event = match kind {
            1 => PlayerEvent::KeyDown {
                key: key(code, unicode),
            },
            2 => PlayerEvent::KeyUp {
                key: key(code, unicode),
            },
            3 => PlayerEvent::MouseMove { x, y },
            4 => PlayerEvent::MouseDown {
                x,
                y,
                button,
                index: None,
            },
            5 => PlayerEvent::MouseUp { x, y, button },
            6 => PlayerEvent::MouseWheel {
                delta: MouseWheelDelta::Lines(y),
            },
            7 => PlayerEvent::TextInput {
                codepoint: char::from_u32(unicode).unwrap_or('\0'),
            },
            _ => return Err("Unsupported Flash input".into()),
        };
        let mut player = flash.player.lock().map_err(|e| e.to_string())?;
        player.handle_event(event);
        if kind == 1 {
            let control = match code {
                8 => Some(TextControlCode::Backspace),
                13 => Some(TextControlCode::Enter),
                46 => Some(TextControlCode::Delete),
                _ => None,
            };
            if let Some(code) = control {
                player.handle_event(PlayerEvent::TextControl { code });
            }
        }
        Ok(true)
    })
}
