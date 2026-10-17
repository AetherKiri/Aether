// SPDX-License-Identifier: MPL-2.0
// Included in MotionManager's module in the build-tree overlay.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct HostMotionSnapshot {
    alpha: AlphaMotionContainer,
    position: MoveMotionContainer,
    rotation: RotationMotionContainer,
    scale: ScaleMotionContainer,
    z: ZMotionContainer,
    camera: V3dMotionContainer,
    sprite: SpriteAnimContainer,
    snow: SnowMotionContainer,
    lip: LipMotionContainer,
}

impl MotionManager {
    pub(crate) fn capture_host_motions(&self) -> HostMotionSnapshot {
        HostMotionSnapshot {
            alpha: self.alpha_motion_container.clone(),
            position: self.move_motion_container.clone(),
            rotation: self.rotation_motion_container.clone(),
            scale: self.scale_motion_container.clone(),
            z: self.z_motion_container.clone(),
            camera: self.v3d_motion_container.clone(),
            sprite: self.sprite_anim_container.clone(),
            snow: self.snow_motion_container.clone(),
            lip: self.lip_motion_container.clone(),
        }
    }

    pub(crate) fn apply_host_motions(&mut self, state: &HostMotionSnapshot) {
        // Timelines store relative elapsed milliseconds, not wall-clock instants.
        // Restore them after the base snapshot has reset the old session's motions.
        self.alpha_motion_container = state.alpha.clone();
        self.move_motion_container = state.position.clone();
        self.rotation_motion_container = state.rotation.clone();
        self.scale_motion_container = state.scale.clone();
        self.z_motion_container = state.z.clone();
        self.v3d_motion_container = state.camera.clone();
        self.sprite_anim_container = state.sprite.clone();
        self.snow_motion_container = state.snow.clone();
        self.lip_motion_container = state.lip.clone();
        // live_end is an upstream scan cache, absent from Aether's V2 layout.
        // Serde skips it; restoring all slots makes legacy in-flight motions
        // visible again without extending the wire format.
        self.alpha_motion_container.rebuild_host_motion_bounds();
        self.move_motion_container.rebuild_host_motion_bounds();
        self.rotation_motion_container.rebuild_host_motion_bounds();
        self.scale_motion_container.rebuild_host_motion_bounds();
        self.z_motion_container.rebuild_host_motion_bounds();
    }
}

#[cfg(all(test, not(feature = "no_std")))]
mod host_motion_snapshot_tests {
    use super::*;
    use crate::subsystem::snapshot_codec;

    fn assert_legacy_layout<T: Serialize + serde::de::DeserializeOwned>(
        current: &T,
        legacy: &impl Serialize,
        expected_size: usize,
    ) {
        let bytes = snapshot_codec::encode(legacy).unwrap();
        assert_eq!(bytes.len(), expected_size);
        assert_eq!(snapshot_codec::encode(current).unwrap(), bytes);
        let restored: T = snapshot_codec::decode(&bytes).unwrap();
        assert_eq!(snapshot_codec::encode(&restored).unwrap(), bytes);
    }

    #[test]
    fn scan_bounds_do_not_change_legacy_motion_bytes() {
        // Field order and byte sizes from the Aether V2 containers at 81a8b685.
        // A tuple has the same bincode representation as the original struct.
        assert_legacy_layout(
            &AlphaMotionContainer::new(),
            &(
                vec![alpha::AlphaMotion::new(); 256],
                0u32,
                (0..256u16).collect::<Vec<_>>(),
            ),
            6164,
        );
        assert_legacy_layout(
            &MoveMotionContainer::new(),
            &(
                (0..512).map(normal_move::MoveMotion::new).collect::<Vec<_>>(),
                (0..512u16).rev().collect::<Vec<_>>(),
            ),
            19472,
        );
        assert_legacy_layout(
            &RotationMotionContainer::new(),
            &(
                (0..512).map(rotation_move::RotationMotion::new).collect::<Vec<_>>(),
                (0..512u16).rev().collect::<Vec<_>>(),
            ),
            13328,
        );
        assert_legacy_layout(
            &ScaleMotionContainer::new(),
            &(
                (0..512).map(s2_move::ScaleMotion::new).collect::<Vec<_>>(),
                (0..512u16).rev().collect::<Vec<_>>(),
            ),
            15376,
        );
        assert_legacy_layout(
            &ZMotionContainer::new(),
            &(
                (0..512).map(z_move::ZMotion::new).collect::<Vec<_>>(),
                (0..512u16).rev().collect::<Vec<_>>(),
            ),
            13328,
        );
    }

    fn tick(manager: &mut MotionManager, elapsed: i32) {
        let prims = &manager.prim_manager;
        manager.alpha_motion_container.exec_alpha_motion(prims, false, elapsed);
        manager.move_motion_container.exec_move_motion(prims, false, elapsed);
        manager.rotation_motion_container.exec_rotation_motion(prims, false, elapsed);
        manager.scale_motion_container.exec_scale_motion(prims, false, elapsed);
        manager.z_motion_container.exec_z_motion(prims, false, elapsed);
    }

    fn assert_running(manager: &MotionManager, expected: bool) {
        assert_eq!(manager.alpha_motion_container.test_motion(1), expected);
        assert_eq!(manager.move_motion_container.test_motion(1), expected);
        assert_eq!(manager.rotation_motion_container.test_motion(1), expected);
        assert_eq!(manager.scale_motion_container.test_motion(1), expected);
        assert_eq!(manager.z_motion_container.test_motion(1), expected);
    }

    #[test]
    fn legacy_motions_resume_at_saved_elapsed_time() {
        let mut original = MotionManager::new();
        original.prim_manager.get_prim(1).set_paused(false);
        original.prim_manager.get_prim(1).set_parent(INVAILD_PRIM_HANDLE);
        original.alpha_motion_container
            .push_motion(1, 0, 200, 100, AlphaMotionType::Linear, false).unwrap();
        original.move_motion_container
            .push_motion(1, 0, 0, 200, 400, 100, MoveMotionType::Linear, false).unwrap();
        original.rotation_motion_container
            .push_motion(1, 0, 200, 100, RotationMotionType::Linear, false).unwrap();
        original.scale_motion_container
            .push_motion(1, 0, 0, 200, 400, 100, ScaleMotionType::Linear, false).unwrap();
        original.z_motion_container
            .push_motion(1, 0, 200, 100, ZMotionType::Linear, false).unwrap();
        tick(&mut original, 25);
        let bytes = snapshot_codec::encode(&original.capture_host_motions()).unwrap();
        let state: HostMotionSnapshot = snapshot_codec::decode(&bytes).unwrap();

        let mut restored = MotionManager::new();
        restored.prim_manager.get_prim(1).set_paused(false);
        restored.prim_manager.get_prim(1).set_parent(INVAILD_PRIM_HANDLE);
        restored.apply_host_motions(&state);
        assert_running(&restored, true);
        assert_eq!(snapshot_codec::encode(&restored.capture_host_motions()).unwrap(), bytes);
        tick(&mut restored, 25);
        {
            let prim = restored.prim_manager.get_prim(1);
            assert_eq!(prim.get_alpha(), 100);
            assert_eq!((prim.get_x(), prim.get_y()), (100, 200));
            assert_eq!(prim.get_rotation(), 100);
            assert_eq!((prim.get_factor_x(), prim.get_factor_y()), (100, 200));
            assert_eq!(prim.get_z(), 100);
        }
        tick(&mut restored, 50);
        assert_running(&restored, false);
    }
}
