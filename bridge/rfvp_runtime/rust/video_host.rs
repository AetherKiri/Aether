// SPDX-License-Identifier: MPL-2.0
// Included in the build-tree videoplayer module. Each MovieSource adjusts its
// private playback clock; the shared audio backend pauses all soundtracks.
impl VideoPlayerManager {
    pub fn pause_host(&mut self, paused: bool, elapsed: std::time::Duration) {
        if let Some(source) = self.source.as_mut() {
            source.pause_host(paused, elapsed);
        }
    }
}

fn resume_host_clock(
    clock: &mut Option<crate::platform_time::Instant>,
    paused: bool,
    elapsed: std::time::Duration,
) {
    if !paused {
        if let Some(started) = clock.as_mut() {
            *started += elapsed;
        }
    }
}

#[cfg(test)]
mod host_video_tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    #[test]
    fn host_video_clock_excludes_paused_time() {
        let start = Instant::now();
        let mut clock = Some(start);
        let elapsed = Duration::from_secs(30);
        resume_host_clock(&mut clock, true, Duration::ZERO);
        assert_eq!(clock, Some(start));
        resume_host_clock(&mut clock, false, elapsed);
        assert_eq!(clock, Some(start + elapsed));
        let mut waiting_for_first_frame = None;
        resume_host_clock(&mut waiting_for_first_frame, false, elapsed);
        assert!(waiting_for_first_frame.is_none());
    }

    #[test]
    fn host_video_pause_reaches_the_active_source() {
        struct Source(Arc<Mutex<Vec<(bool, Duration)>>>);
        impl MovieSource for Source {
            fn next_frame(&mut self) -> Result<Option<MovieFrame>> {
                Ok(None)
            }
            fn is_finished(&mut self) -> Result<bool> {
                Ok(false)
            }
            fn stop(self: Box<Self>) {}
            fn pause_host(&mut self, paused: bool, elapsed: Duration) {
                self.0.lock().unwrap().push((paused, elapsed));
            }
        }
        let calls = Arc::new(Mutex::new(Vec::new()));
        let mut manager = VideoPlayerManager::new();
        manager.pause_host(true, Duration::ZERO);
        manager.source = Some(Box::new(Source(calls.clone())));
        manager.pause_host(true, Duration::ZERO);
        manager.pause_host(false, Duration::from_secs(30));
        assert_eq!(
            *calls.lock().unwrap(),
            vec![(true, Duration::ZERO), (false, Duration::from_secs(30))]
        );
    }
}
