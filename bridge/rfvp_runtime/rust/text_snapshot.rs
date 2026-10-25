// SPDX-License-Identifier: MPL-2.0
// Included in TextManager's module; the base snapshot already owns the text,
// formatting, visible columns and wait points. Preserve its coroutine linkage too.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct HostTextPlayback {
    reveal_carry: i64,
    sync_wait_thread: Option<u32>,
    sync_wait_active: bool,
}

#[cfg(test)]
mod host_snapshot_tests {
    use super::*;

    #[cfg(not(feature = "no_std"))]
    #[test]
    fn text_playback_keeps_legacy_wire_layout() {
        let state = HostTextPlayback {
            reveal_carry: 13,
            sync_wait_thread: Some(7),
            sync_wait_active: true,
        };
        // Frozen V2 order: i64 carry, Option<u32> thread, bool active.
        let expected = [13, 0, 0, 0, 0, 0, 0, 0, 1, 7, 0, 0, 0, 1];
        let bytes = crate::subsystem::snapshot_codec::encode(&state).unwrap();
        assert_eq!(bytes, expected);
        let restored: HostTextPlayback = crate::subsystem::snapshot_codec::decode(&expected).unwrap();
        assert_eq!(restored.reveal_carry, 13);
        assert_eq!(restored.sync_wait_thread, Some(7));
        assert!(restored.sync_wait_active);
    }

    #[test]
    fn text_reveal_restores_its_waiting_coroutine() {
        let mut manager = TextManager::new();
        manager.items[0].reveal_carry = 13;
        manager.items[0].sync_wait_thread = Some(7);
        manager.items[0].sync_wait_active = true;
        let base = manager.capture_snapshot_v1();
        let bytes = crate::subsystem::snapshot_codec::encode(&manager.capture_host_playback()).unwrap();
        let playback: Vec<HostTextPlayback> = crate::subsystem::snapshot_codec::decode(&bytes).unwrap();
        manager.items[0].sync_wait_thread = Some(9);
        manager.apply_snapshot_v1(&base);
        manager.apply_host_playback(&playback);
        assert_eq!(manager.items[0].reveal_carry, 13);
        assert_eq!(manager.items[0].sync_wait_thread, Some(7));
        assert!(manager.items[0].sync_wait_active);
        assert_eq!(manager.collect_completed_sync_print_waiters(), vec![7]);
        assert!(manager.collect_completed_sync_print_waiters().is_empty());
        manager.apply_host_playback(&[]);
        assert_eq!(manager.items[0].sync_wait_thread, None);
        assert!(!manager.items[0].sync_wait_active);
    }
}

impl TextManager {
    pub(crate) fn capture_host_playback(&self) -> Vec<HostTextPlayback> {
        self.items
            .iter()
            .map(|item| HostTextPlayback {
                reveal_carry: item.reveal_carry,
                sync_wait_thread: item.sync_wait_thread,
                sync_wait_active: item.sync_wait_active,
            })
            .collect()
    }

    pub(crate) fn apply_host_playback(&mut self, state: &[HostTextPlayback]) {
        for (index, item) in self.items.iter_mut().enumerate() {
            item.reveal_carry = state.get(index).map_or(0, |s| s.reveal_carry);
            item.sync_wait_thread = state.get(index).and_then(|s| s.sync_wait_thread);
            item.sync_wait_active = state.get(index).is_some_and(|s| s.sync_wait_active);
        }
    }
}
