// SPDX-License-Identifier: MPL-2.0
// Included in save_state. Keep the original V1 binary layout readable and put
// resumable animation/text state in a separately versioned RFVS payload.
#[cfg(not(feature = "no_std"))]
use bincode::Options;

use crate::subsystem::resources::{
    motion_manager::HostMotionSnapshot, text_manager::HostTextPlayback,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct HostPlaybackSnapshot {
    motions: HostMotionSnapshot,
    text: Vec<HostTextPlayback>,
}

impl HostPlaybackSnapshot {
    fn capture(game: &GameData) -> Self {
        Self {
            motions: game.motion_manager.capture_host_motions(),
            text: game.motion_manager.text_manager.capture_host_playback(),
        }
    }

    fn apply(&self, game: &mut GameData) {
        game.motion_manager.apply_host_motions(&self.motions);
        game.motion_manager
            .text_manager
            .apply_host_playback(&self.text);
    }
}

#[derive(Serialize, Deserialize)]
struct HostSaveEnvelopeV2 {
    version: u16,
    base: SaveStateSnapshotV1,
    playback: HostPlaybackSnapshot,
}

// Aether uses the desktop RFVS codec. Keep its fixed-width little-endian
// encoding and byte limit local: upstream snapshot_codec also serves postcard
// targets and no longer exposes the old save_state::bincode_opts helper.
#[cfg(not(feature = "no_std"))]
fn host_bincode_opts() -> impl bincode::Options {
    bincode::DefaultOptions::new()
        .with_fixint_encoding()
        .with_little_endian()
        .reject_trailing_bytes()
        .with_limit(MAX_STATE_PAYLOAD_BYTES as u64)
}

#[cfg(not(feature = "no_std"))]
fn encode_host_snapshot(snapshot: &SaveStateSnapshotV1) -> Result<Vec<u8>> {
    match &snapshot.host_playback {
        Some(playback) => Ok(host_bincode_opts().serialize(&HostSaveEnvelopeV2 {
            version: 2,
            base: snapshot.clone(),
            playback: playback.clone(),
        })?),
        // Also used to round-trip a legacy snapshot without inventing lost state.
        None => Ok(host_bincode_opts().serialize(snapshot)?),
    }
}

#[cfg(not(feature = "no_std"))]
fn decode_host_snapshot(payload: &[u8]) -> Result<SaveStateSnapshotV1> {
    if payload.len() > MAX_STATE_PAYLOAD_BYTES {
        bail!("rfvp save-state payload exceeds maximum size");
    }
    let version = payload.get(..2).map(|v| u16::from_le_bytes([v[0], v[1]]));
    match version {
        Some(1) => Ok(host_bincode_opts().deserialize(payload)?),
        Some(2) => {
            let envelope: HostSaveEnvelopeV2 = host_bincode_opts().deserialize(payload)?;
            if envelope.base.version != 1 {
                bail!("Unsupported rfvp V2 base version: {}", envelope.base.version);
            }
            let mut snapshot = envelope.base;
            snapshot.host_playback = Some(envelope.playback);
            Ok(snapshot)
        }
        _ => bail!("Unsupported or truncated rfvp save-state version: {version:?}"),
    }
}

#[cfg(all(test, not(feature = "no_std")))]
mod host_snapshot_tests {
    use super::*;
    use crate::subsystem::resources::motion_manager::MotionManager;

    #[test]
    fn versioned_payload_preserves_legacy_wire_format() {
        let motion = MotionManager::new();
        let mut snapshot = SaveStateSnapshotV1 {
            host_playback: None,
            version: 1,
            motion: motion.capture_snapshot_v1(),
            audio: AudioSnapshotV1 {
                bgm: BgmPlayerSnapshotV1 {
                    version: 1,
                    slots: vec![],
                },
                se: SePlayerSnapshotV1 {
                    version: 1,
                    slots: vec![],
                },
            },
            globals_non_volatile: vec![],
            vm: ThreadManager::new().capture_snapshot_v1(),
        };
        let legacy = host_bincode_opts().serialize(&snapshot).unwrap();
        assert_eq!(&legacy[..2], &[1, 0]);
        assert_eq!(encode_host_snapshot(&snapshot).unwrap(), legacy);
        let decoded = decode_host_snapshot(&legacy).unwrap();
        assert!(decoded.host_playback.is_none());
        assert_eq!(encode_host_snapshot(&decoded).unwrap(), legacy);

        snapshot.host_playback = Some(HostPlaybackSnapshot {
            motions: motion.capture_host_motions(),
            text: motion.text_manager.capture_host_playback(),
        });
        let current = encode_host_snapshot(&snapshot).unwrap();
        assert_eq!(&current[..2], &[2, 0]);
        let decoded = decode_host_snapshot(&current).unwrap();
        assert!(decoded.host_playback.is_some());
        assert_eq!(encode_host_snapshot(&decoded).unwrap(), current);
        assert_eq!(host_bincode_opts().serialize(&decoded).unwrap(), legacy);
        assert!(decode_host_snapshot(&current[..current.len() - 1]).is_err());
        assert!(decode_host_snapshot(&[3, 0]).is_err());
        assert!(decode_host_snapshot(&[2]).is_err());
        let mut trailing = current.clone();
        trailing.push(0);
        assert!(decode_host_snapshot(&trailing).is_err());
        let mut invalid_base = current;
        invalid_base[2..4].copy_from_slice(&2u16.to_le_bytes());
        assert!(decode_host_snapshot(&invalid_base).is_err());
    }

    fn graph_source(compressed_pixels: &[u8]) -> Vec<u8> {
        // Original 2x1 NVSG fixture with nonzero geometry and compressed BGRA pixels.
        let mut bytes = b"hzc1".to_vec();
        bytes.extend_from_slice(&8u32.to_le_bytes());
        bytes.extend_from_slice(&32u32.to_le_bytes());
        bytes.extend_from_slice(b"NVSG");
        for field in [0u16, 1, 2, 1, 11, 13, 1, 0] {
            bytes.extend_from_slice(&field.to_le_bytes());
        }
        bytes.extend_from_slice(&[0; 12]);
        bytes.extend_from_slice(compressed_pixels);
        bytes
    }

    fn roundtrip_named_graph_v2(
        graph: &crate::subsystem::resources::graph_buff::GraphBuff,
    ) -> SaveStateSnapshotV1 {
        let motion = MotionManager::new();
        let mut base_motion = motion.capture_snapshot_v1();
        base_motion.textures.push(graph.capture_snapshot_with_id(7));
        let snapshot = SaveStateSnapshotV1 {
            host_playback: Some(HostPlaybackSnapshot {
                motions: motion.capture_host_motions(),
                text: motion.text_manager.capture_host_playback(),
            }),
            version: 1,
            motion: base_motion,
            audio: AudioSnapshotV1 {
                bgm: BgmPlayerSnapshotV1 { version: 1, slots: vec![] },
                se: SePlayerSnapshotV1 { version: 1, slots: vec![] },
            },
            globals_non_volatile: vec![],
            vm: ThreadManager::new().capture_snapshot_v1(),
        };
        let encoded = encode_host_snapshot(&snapshot).unwrap();
        assert_eq!(&encoded[..2], &[2, 0]);
        let decoded = decode_host_snapshot(&encoded).unwrap();
        assert!(decoded.host_playback.is_some());
        assert_eq!(encode_host_snapshot(&decoded).unwrap(), encoded);
        assert_eq!(decoded.motion.textures.len(), 1);
        decoded
    }

    #[test]
    fn version_two_preserves_overlaid_named_graph_pixels_and_geometry() {
        use crate::subsystem::resources::{graph_buff::GraphBuff, vfs::Vfs};

        let path = "host-snapshot/overlaid.nvsg";
        let mut graph = GraphBuff::new();
        // BGRA: [200, 160, 120, 255, 80, 40, 20, 255].
        graph.load_texture(path, graph_source(&[
            120, 156, 59, 177, 160, 226, 127, 128, 134, 200, 127, 0, 21, 82, 4, 107,
        ])).unwrap();
        assert!(graph.capture_snapshot_with_id(7).rgba.is_none());
        graph.set_color_tone(50, 25, 75);
        // Simulate the pixel write and dirty marker used by parts composition.
        graph.texture.as_mut().unwrap().as_mut_rgba8().unwrap()
            .put_pixel(0, 0, image::Rgba([9, 8, 7, 255]));
        graph.mark_pixels_overlaid();
        graph.offset_x = 3;
        graph.offset_y = 5;
        graph.u = 1;
        graph.v = 1;
        graph.display_width = 6;
        graph.display_height = 3;
        let pixels = vec![9, 8, 7, 255, 10, 10, 60, 255];
        assert_eq!(graph.texture.as_ref().unwrap().to_rgba8().into_raw(), pixels);
        assert_eq!(graph.capture_snapshot_with_id(7).rgba.as_ref(), Some(&pixels));
        let decoded = roundtrip_named_graph_v2(&graph);
        assert_eq!(decoded.motion.textures[0].rgba.as_ref(), Some(&pixels));

        // Missing and valid-but-different assets must both restore the embedded
        // edits. Replacement BGRA pixels: [10, 20, 30, 255, 40, 50, 60, 255].
        let replacement = graph_source(&[
            120, 156, 227, 18, 145, 251, 175, 97, 100, 243, 31, 0, 9, 64, 2, 209,
        ]);
        for replacement in [None, Some(replacement)] {
            let mut vfs = Vfs::default();
            if let Some(bytes) = replacement {
                let mut different = GraphBuff::new();
                different.load_texture(path, bytes.clone()).unwrap();
                assert_ne!(different.texture.as_ref().unwrap().to_rgba8().into_raw(), pixels);
                vfs.add_loose_file(path, bytes);
            }
            let mut restored = MotionManager::new();
            restored.apply_snapshot_v1(&decoded.motion, &vfs).unwrap();
            let graph = restored.get_texture(7);
            assert_eq!(graph.texture.as_ref().unwrap().to_rgba8().into_raw(), pixels);
            assert_eq!(graph.texture_path, path);
            assert!(graph.texture_ready);
            assert_eq!((graph.width, graph.height), (2, 1));
            assert_eq!((graph.offset_x, graph.offset_y, graph.u, graph.v), (3, 5, 1, 1));
            assert_eq!((graph.display_width, graph.display_height), (6, 3));
            // Restored named overlays remain embedded through another V2 save.
            let resaved = roundtrip_named_graph_v2(graph);
            assert_eq!(resaved.motion.textures[0].rgba.as_ref(), Some(&pixels));
        }
    }

    #[test]
    fn version_two_replays_last_graph_rgb_once_with_source_geometry() {
        use crate::subsystem::resources::{graph_buff::GraphBuff, vfs::Vfs};

        let path = "host-snapshot/toned.nvsg";
        let original = graph_source(&[
            120, 156, 59, 177, 160, 226, 127, 128, 134, 200, 127, 0, 21, 82, 4, 107,
        ]);
        let mut graph = GraphBuff::new();
        graph.load_texture(path, original.clone()).unwrap();
        graph.set_color_tone(50, 50, 50);
        graph.set_color_tone(50, 25, 75);
        let compounded = graph.texture.as_ref().unwrap().to_rgba8().into_raw();
        assert_eq!(compounded, vec![30, 20, 75, 255, 5, 5, 30, 255]);
        graph.offset_x = 3;
        graph.offset_y = 5;
        graph.u = 0;
        graph.v = 1;
        graph.display_width = 6;
        graph.display_height = 3;
        let decoded = roundtrip_named_graph_v2(&graph);
        let saved = &decoded.motion.textures[0];
        assert!(saved.rgba.is_none());
        assert_eq!(saved.texture_path, path);
        assert_eq!((saved.r_value, saved.g_value, saved.b_value), (50, 25, 75));

        let mut vfs = Vfs::default();
        vfs.add_loose_file(path, original);
        let mut restored = MotionManager::new();
        restored.apply_snapshot_v1(&decoded.motion, &vfs).unwrap();
        let graph = restored.get_texture(7);
        let pixels = graph.texture.as_ref().unwrap().to_rgba8().into_raw();
        assert_eq!(pixels, vec![60, 40, 150, 255, 10, 10, 60, 255]);
        assert_ne!(pixels, compounded);
        assert_eq!(graph.texture_path, path);
        assert!(graph.texture_ready);
        assert_eq!((graph.get_r_value(), graph.get_g_value(), graph.get_b_value()), (50, 25, 75));
        assert_eq!((graph.width, graph.height), (2, 1));
        assert_eq!((graph.offset_x, graph.offset_y, graph.u, graph.v), (11, 13, 1, 0));
        assert_eq!((graph.display_width, graph.display_height), (2, 1));
        assert!(roundtrip_named_graph_v2(graph).motion.textures[0].rgba.is_none());

        let error = MotionManager::new()
            .apply_snapshot_v1(&decoded.motion, &Vfs::default())
            .unwrap_err();
        assert!(error.to_string().contains(path));
    }

    #[test]
    fn desktop_prim_snapshot_preserves_legacy_field_order() {
        use crate::subsystem::resources::prim::{Prim, PrimManagerSnapshotV1};
        let prim = Prim::new().capture_snapshot_v1();
        let snapshot = PrimManagerSnapshotV1 {
            custom_root_prim_id: 7,
            prims: vec![prim.clone()],
            ids: vec![],
        };
        // Before upstream's PlayStation-only sparse ids, the wire contained
        // exactly these two fields. An empty extra Vec would still break it.
        let legacy = host_bincode_opts().serialize(&(7u16, vec![prim])).unwrap();
        assert_eq!(host_bincode_opts().serialize(&snapshot).unwrap(), legacy);
        let decoded: PrimManagerSnapshotV1 = host_bincode_opts().deserialize(&legacy).unwrap();
        assert_eq!(decoded.custom_root_prim_id, 7);
        assert_eq!(decoded.prims, snapshot.prims);
        assert!(decoded.ids.is_empty());
    }

    #[test]
    fn host_codec_keeps_its_byte_limit() {
        // Vec<u8> is encoded as an eight-byte length and its contents.
        let bytes = [0u8; 9];
        assert!(host_bincode_opts().with_limit(8).serialize(&bytes.to_vec()).is_err());
        let encoded = host_bincode_opts().with_limit(17).serialize(&bytes.to_vec()).unwrap();
        assert_eq!(encoded.len(), 17);
        assert_eq!(host_bincode_opts().deserialize::<Vec<u8>>(&encoded).unwrap(), bytes);

        // Bincode's slice decoder does not enforce with_limit. The production
        // entry point must reject an oversized slice before decoding either version.
        let mut oversized = vec![0u8; MAX_STATE_PAYLOAD_BYTES + 1];
        for version in [1u16, 2] {
            oversized[..2].copy_from_slice(&version.to_le_bytes());
            let error = decode_host_snapshot(&oversized).unwrap_err();
            assert_eq!(error.to_string(), "rfvp save-state payload exceeds maximum size");
        }
    }

    #[test]
    fn fixed_motion_buffer_rejects_wrong_lengths() {
        #[derive(Serialize, Deserialize)]
        struct Buffer(#[serde(with = "host_array")] [u8; 64]);
        let bytes = host_bincode_opts().serialize(&Buffer([7; 64])).unwrap();
        assert_eq!(
            host_bincode_opts().deserialize::<Buffer>(&bytes).unwrap().0,
            [7; 64]
        );
        for length in [0, 63, 65] {
            let wrong = host_bincode_opts().serialize(&vec![7u8; length]).unwrap();
            assert!(host_bincode_opts().deserialize::<Buffer>(&wrong).is_err());
        }
        // Reject a forged length before trying to reserve attacker-sized storage.
        assert!(host_bincode_opts()
            .deserialize::<Buffer>(&u64::MAX.to_le_bytes())
            .is_err());
    }
}

// Serde's built-in array implementations stop at 32 entries. Snow's fixed
// buffers use a length-checked sequence; no pointer or machine address is saved.
pub(crate) mod host_array {
    use core::{fmt, marker::PhantomData};
    use serde::de::{Error, SeqAccess, Visitor};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    #[cfg(feature = "no_std")]
    use alloc::vec::Vec;
    pub fn serialize<T: Serialize, S: Serializer, const N: usize>(
        items: &[T; N],
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        items.as_slice().serialize(serializer)
    }
    pub fn deserialize<'de, T: Deserialize<'de>, D: Deserializer<'de>, const N: usize>(
        deserializer: D,
    ) -> Result<[T; N], D::Error> {
        struct FixedVisitor<T, const N: usize>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>, const N: usize> Visitor<'de> for FixedVisitor<T, N> {
            type Value = [T; N];

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "exactly {N} motion buffer entries")
            }

            fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Self::Value, A::Error> {
                if let Some(length) = sequence.size_hint() {
                    if length != N {
                        return Err(A::Error::invalid_length(length, &self));
                    }
                }
                // Allocate only the fixed expected length, never the encoded length.
                let mut items = Vec::with_capacity(N);
                for index in 0..N {
                    items.push(sequence.next_element()?.ok_or_else(|| {
                        A::Error::invalid_length(index, &self)
                    })?);
                }
                if sequence.next_element::<T>()?.is_some() {
                    return Err(A::Error::invalid_length(N + 1, &self));
                }
                items.try_into().map_err(|_| {
                    A::Error::custom("Invalid fixed motion buffer length")
                })
            }
        }
        deserializer.deserialize_seq(FixedVisitor::<T, N>(PhantomData))
    }
}
