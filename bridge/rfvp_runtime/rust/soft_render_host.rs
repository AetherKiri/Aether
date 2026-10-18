// SPDX-License-Identifier: MPL-2.0
// Included in the software renderer's module in the build-tree overlay.
use crate::aetherkiri_host::{HostGpuCallbacks, HostGpuPoint, HostGpuRect};

const HOST_GPU_BLEND_ALPHA_D: u32 = 2;
// Untagged triangle mode 1 is SRCALPHA/ONE with destination alpha held.
// RFVP always clears its render target opaque, so this matches PrimSetBlend.
const HOST_GPU_BLEND_ADDITIVE: u32 = 1;
const HOST_GPU_TRIANGLE_TVP_BLEND: u32 = 0x0001_0000;
const HOST_GPU_TRIANGLE_SOURCE_NEAREST: u32 = 0x1000_0000;
const HOST_GPU_TRIANGLE_SOURCE_STRAIGHT_LINEAR: u32 = 0x0400_0000;

#[derive(Debug)]
struct HostGpuTexture {
    handle: u64,
    generation: u64,
    width: u32,
    height: u32,
    tint: [u8; 3],
}

#[derive(Debug)]
struct HostGpuDrawBatch {
    source: u64,
    clip: HostGpuRect,
    rects: Vec<HostGpuRect>,
    dst: Vec<HostGpuPoint>,
    src: Vec<HostGpuPoint>,
    opacity: f32,
    opacity_bits: u32,
    blend: u32,
}

#[derive(Debug)]
struct HostGpuRenderer {
    callbacks: HostGpuCallbacks,
    target: u64,
    width: u32,
    height: u32,
    batch_token: u64,
    frame_active: bool,
    // A retained target can belong to an older frame while a mask dissolve is
    // rendered on the CPU. Only expose/read it when it owns the latest frame.
    frame_ready: bool,
    failed: bool,
    pending: Option<HostGpuDrawBatch>,
    graph_cache: std::collections::HashMap<u16, HostGpuTexture>,
    color_cache: std::collections::HashMap<u32, u64>,
}

impl HostGpuRenderer {
    fn new(callbacks: HostGpuCallbacks, width: u32, height: u32) -> Self {
        Self {
            callbacks,
            // Core construction happens on the runtime's asynchronous startup
            // thread. Delay RenderingDevice access until the first host tick,
            // which runs on Godot's main thread.
            target: 0,
            width,
            height,
            batch_token: 0,
            frame_active: false,
            frame_ready: false,
            failed: false,
            pending: None,
            graph_cache: std::collections::HashMap::new(),
            color_cache: std::collections::HashMap::new(),
        }
    }

    fn begin_frame(&mut self) -> bool {
        if self.frame_active {
            return false;
        }
        self.frame_ready = false;
        if self.target == 0 {
            self.target = unsafe {
                self.callbacks.create_rgba.unwrap()(
                    self.width,
                    self.height,
                    std::ptr::null(),
                    self.width.saturating_mul(4),
                )
            };
            if self.target == 0 {
                return false;
            }
        }
        self.failed = false;
        self.batch_token = unsafe { self.callbacks.begin_batch.unwrap()() };
        if self.batch_token == 0 {
            return false;
        }
        self.frame_active = true;
        let rect = HostGpuRect {
            left: 0,
            top: 0,
            right: self.width as i32,
            bottom: self.height as i32,
        };
        if !unsafe { self.callbacks.clear_rgba.unwrap()(self.target, 0xff00_0000, &rect) } {
            self.failed = true;
        }
        true
    }

    fn end_frame(&mut self) -> bool {
        if !self.frame_active {
            return false;
        }
        self.flush_draws();
        self.frame_active = false;
        let token = std::mem::take(&mut self.batch_token);
        let ended = unsafe { self.callbacks.end_batch.unwrap()(token) };
        self.frame_ready = ended && !self.failed;
        self.frame_ready
    }

    fn release(&self, handle: u64) {
        if handle != 0 {
            unsafe { self.callbacks.release_texture.unwrap()(handle) };
        }
    }

    fn flush_draws(&mut self) {
        let Some(batch) = self.pending.take() else {
            return;
        };
        if !unsafe {
            self.callbacks.draw_triangles.unwrap()(
                self.target,
                batch.source,
                (batch.dst.len() / 3) as u32,
                &batch.clip,
                batch.dst.as_ptr(),
                batch.src.as_ptr(),
                batch.opacity,
                batch.blend,
            )
        } {
            self.failed = true;
        }
    }

    fn enqueue_draw(
        &mut self,
        source: u64,
        clip: HostGpuRect,
        dst: &[HostGpuPoint; 6],
        src: &[HostGpuPoint; 6],
        opacity: f32,
        blend: u32,
    ) {
        let opacity = opacity.clamp(0.0, 1.0);
        let opacity_bits = opacity.to_bits();
        let can_append = self.pending.as_ref().is_some_and(|batch| {
            let union = HostGpuRect {
                left: batch.clip.left.min(clip.left),
                top: batch.clip.top.min(clip.top),
                right: batch.clip.right.max(clip.right),
                bottom: batch.clip.bottom.max(clip.bottom),
            };
            let area = |rect: &HostGpuRect| {
                u64::from((rect.right - rect.left).max(0) as u32)
                    * u64::from((rect.bottom - rect.top).max(0) as u32)
            };
            let disjoint = batch.rects.iter().all(|other| {
                clip.right <= other.left
                    || clip.left >= other.right
                    || clip.bottom <= other.top
                    || clip.top >= other.bottom
            });
            let covered_area = batch.rects.iter().map(area).sum::<u64>() + area(&clip);
            batch.source == source
                && batch.opacity_bits == opacity_bits
                && batch.blend == blend
                // The TVP shader stops after the first covering triangle, so
                // only disjoint quads can share one dispatch without changing
                // authored blend order. Bound the union as well: scattered
                // snowflakes must not turn into a full-screen dispatch.
                && disjoint
                && area(&union) <= covered_area.saturating_mul(4)
                && batch.dst.len() + dst.len() <= 16 * 6
        });
        if !can_append {
            self.flush_draws();
            self.pending = Some(HostGpuDrawBatch {
                source,
                clip,
                rects: Vec::with_capacity(16),
                dst: Vec::with_capacity(64 * 3),
                src: Vec::with_capacity(64 * 3),
                opacity,
                opacity_bits,
                blend,
            });
        }
        let batch = self.pending.as_mut().unwrap();
        batch.clip.left = batch.clip.left.min(clip.left);
        batch.clip.top = batch.clip.top.min(clip.top);
        batch.clip.right = batch.clip.right.max(clip.right);
        batch.clip.bottom = batch.clip.bottom.max(clip.bottom);
        batch.rects.push(clip);
        batch.dst.extend_from_slice(dst);
        batch.src.extend_from_slice(src);
    }

    fn prune_graphs(&mut self, graphs: &[GraphBuff]) {
        let stale: Vec<u16> = self
            .graph_cache
            .keys()
            .copied()
            .filter(|graph_id| {
                graphs
                    .get(*graph_id as usize)
                    .is_none_or(|graph| !graph.get_texture_ready() || graph.get_texture().is_none())
            })
            .collect();
        for id in stale {
            if let Some(texture) = self.graph_cache.remove(&id) {
                self.release(texture.handle);
            }
        }
    }

    fn graph_texture(
        &mut self,
        graph_id: u16,
        graph: &GraphBuff,
        image: &DynamicImage,
        color: Vec4,
    ) -> Option<(u64, u32, u32, bool)> {
        let (width, height) = image.dimensions();
        if width == 0 || height == 0 {
            return None;
        }
        let generation = graph.get_generation();
        let tint = [
            (color.x.clamp(0.0, 1.0) * 255.0).round() as u8,
            (color.y.clamp(0.0, 1.0) * 255.0).round() as u8,
            (color.z.clamp(0.0, 1.0) * 255.0).round() as u8,
        ];
        if let Some(entry) = self.graph_cache.get(&graph_id) {
            if entry.generation == generation
                && entry.width == width
                && entry.height == height
                && entry.tint == tint
            {
                let nearest = (4064..=4095).contains(&graph_id)
                    || graph.load_kind == GraphBuffLoadKind::GaijiGlyph;
                return Some((entry.handle, width, height, nearest));
            }
            // The queued draw stores this texture handle, so submit it before
            // changing the pixels for a new graph generation or tint.
            self.flush_draws();
        }

        let base: std::borrow::Cow<'_, [u8]> = match image {
            DynamicImage::ImageRgba8(pixels) => std::borrow::Cow::Borrowed(pixels.as_raw()),
            _ => std::borrow::Cow::Owned(image.to_rgba8().into_raw()),
        };
        let rgba: std::borrow::Cow<'_, [u8]> = if tint == [255, 255, 255] {
            base
        } else {
            let mut tinted = base.into_owned();
            for pixel in tinted.chunks_exact_mut(4) {
                for channel in 0..3 {
                    pixel[channel] =
                        ((u16::from(pixel[channel]) * u16::from(tint[channel]) + 127) / 255) as u8;
                }
            }
            std::borrow::Cow::Owned(tinted)
        };
        let rect = HostGpuRect {
            left: 0,
            top: 0,
            right: width as i32,
            bottom: height as i32,
        };
        let handle = if let Some(entry) = self.graph_cache.get_mut(&graph_id) {
            if entry.width == width
                && entry.height == height
                && unsafe {
                    self.callbacks.update_rgba.unwrap()(
                        entry.handle,
                        rgba.as_ptr().cast(),
                        width.saturating_mul(4),
                        &rect,
                    )
                }
            {
                entry.generation = generation;
                entry.tint = tint;
                entry.handle
            } else {
                let old = entry.handle;
                let replacement = unsafe {
                    self.callbacks.create_rgba.unwrap()(
                        width,
                        height,
                        rgba.as_ptr().cast(),
                        width.saturating_mul(4),
                    )
                };
                if replacement == 0 {
                    self.failed = true;
                    return None;
                }
                *entry = HostGpuTexture {
                    handle: replacement,
                    generation,
                    width,
                    height,
                    tint,
                };
                unsafe { self.callbacks.release_texture.unwrap()(old) };
                replacement
            }
        } else {
            let handle = unsafe {
                self.callbacks.create_rgba.unwrap()(
                    width,
                    height,
                    rgba.as_ptr().cast(),
                    width.saturating_mul(4),
                )
            };
            if handle == 0 {
                self.failed = true;
                return None;
            }
            self.graph_cache.insert(
                graph_id,
                HostGpuTexture {
                    handle,
                    generation,
                    width,
                    height,
                    tint,
                },
            );
            handle
        };
        let nearest =
            (4064..=4095).contains(&graph_id) || graph.load_kind == GraphBuffLoadKind::GaijiGlyph;
        Some((handle, width, height, nearest))
    }

    fn color_texture(&mut self, color: Vec4) -> Option<u64> {
        let bytes = [
            (color.x.clamp(0.0, 1.0) * 255.0).round() as u8,
            (color.y.clamp(0.0, 1.0) * 255.0).round() as u8,
            (color.z.clamp(0.0, 1.0) * 255.0).round() as u8,
            255,
        ];
        let key = u32::from_le_bytes(bytes);
        if let Some(handle) = self.color_cache.get(&key) {
            return Some(*handle);
        }
        let handle = unsafe { self.callbacks.create_rgba.unwrap()(1, 1, bytes.as_ptr().cast(), 4) };
        if handle == 0 {
            self.failed = true;
            return None;
        }
        self.color_cache.insert(key, handle);
        Some(handle)
    }

    fn draw_quad(
        &mut self,
        vertices: [Vertex; 4],
        texture: TextureRef<'_>,
        additive: bool,
    ) -> bool {
        if !self.frame_active {
            return false;
        }
        let color = vertices[0].color;
        let (source, source_width, source_height, nearest) = match texture {
            TextureRef::Graph {
                graph_id,
                graph,
                image,
            } => {
                let Some(value) = self.graph_texture(graph_id, graph, image, color) else {
                    return true;
                };
                value
            }
            TextureRef::White => {
                let Some(handle) = self.color_texture(color) else {
                    return true;
                };
                (handle, 1, 1, true)
            }
        };

        if !vertices
            .iter()
            .all(|vertex| vertex.pos.is_finite() && vertex.uv.is_finite())
        {
            self.failed = true;
            return true;
        }
        let points = [
            vertices[0],
            vertices[1],
            vertices[2],
            vertices[2],
            vertices[1],
            vertices[3],
        ];
        let mut dst = [HostGpuPoint { x: 0.0, y: 0.0 }; 6];
        let mut src = dst;
        for (index, vertex) in points.iter().enumerate() {
            dst[index] = HostGpuPoint {
                x: vertex.pos.x as f64,
                y: vertex.pos.y as f64,
            };
            // The bridge shader samples edge coordinates (pixel centres are
            // n + 0.5), while RFVP's software renderer interpolates over
            // [0, dimension - 1]. Preserve that exact mapping for linear and
            // nearest sampling instead of stretching the final texel.
            src[index] = HostGpuPoint {
                x: (vertex.uv.x * source_width.saturating_sub(1) as f32 + 0.5) as f64,
                y: (vertex.uv.y * source_height.saturating_sub(1) as f32 + 0.5) as f64,
            };
        }
        let min_x = vertices
            .iter()
            .map(|vertex| vertex.pos.x)
            .fold(f32::INFINITY, f32::min)
            .floor()
            .clamp(0.0, self.width as f32) as i32;
        let min_y = vertices
            .iter()
            .map(|vertex| vertex.pos.y)
            .fold(f32::INFINITY, f32::min)
            .floor()
            .clamp(0.0, self.height as f32) as i32;
        let max_x = vertices
            .iter()
            .map(|vertex| vertex.pos.x)
            .fold(f32::NEG_INFINITY, f32::max)
            .ceil()
            .clamp(0.0, self.width as f32) as i32;
        let max_y = vertices
            .iter()
            .map(|vertex| vertex.pos.y)
            .fold(f32::NEG_INFINITY, f32::max)
            .ceil()
            .clamp(0.0, self.height as f32) as i32;
        if max_x <= min_x || max_y <= min_y {
            return true;
        }
        let clip = HostGpuRect {
            left: min_x,
            top: min_y,
            right: max_x,
            bottom: max_y,
        };
        let mut blend = if additive {
            HOST_GPU_BLEND_ADDITIVE
        } else {
            HOST_GPU_TRIANGLE_TVP_BLEND | HOST_GPU_BLEND_ALPHA_D
        };
        if nearest {
            blend |= HOST_GPU_TRIANGLE_SOURCE_NEAREST;
        } else {
            blend |= HOST_GPU_TRIANGLE_SOURCE_STRAIGHT_LINEAR;
        }
        self.enqueue_draw(source, clip, &dst, &src, color.w.clamp(0.0, 1.0), blend);
        true
    }

    fn readback(&mut self, pixels: &mut [u8], stride: u32) -> bool {
        if self.frame_active || self.target == 0 {
            return false;
        }
        unsafe {
            self.callbacks.read_rgba.unwrap()(
                self.target,
                pixels.as_mut_ptr().cast(),
                pixels.len(),
                stride,
            )
        }
    }
}

impl Drop for HostGpuRenderer {
    fn drop(&mut self) {
        if self.frame_active {
            self.end_frame();
        }
        for texture in self.graph_cache.values() {
            self.release(texture.handle);
        }
        for handle in self.color_cache.values() {
            self.release(*handle);
        }
        self.release(self.target);
    }
}

impl SoftRenderer {
    pub(crate) fn install_host_gpu(&mut self, callbacks: HostGpuCallbacks) -> bool {
        let renderer = HostGpuRenderer::new(
            callbacks,
            self.framebuffer.width(),
            self.framebuffer.height(),
        );
        self.host_gpu = Some(renderer);
        true
    }

    fn sync_host_gpu_snapshot(&mut self) -> bool {
        // Called before the upstream snapshot loop and before starting or
        // clearing the next frame. CPU mask frames are already up to date.
        if self.sync_host_gpu_framebuffer() {
            return true;
        }
        log::warn!(
            "rfvp GPU snapshot readback failed; skipping mask snapshot and reverting to CPU renderer"
        );
        self.host_gpu.take();
        false
    }

    fn begin_host_gpu_motion_frame(&mut self, motion: &MotionManager) -> bool {
        if matches!(
            motion.get_dissolve_type(),
            DissolveType::MaskFadeIn | DissolveType::MaskFadeInOut | DissolveType::MaskFadeOut
        ) {
            // Upstream composites the prepared mask directly into framebuffer
            // pixels. Render the entire frame there, including scene and HUD,
            // rather than mixing CPU mask pixels with a stale GPU surface.
            if let Some(renderer) = self.host_gpu.as_mut() {
                renderer.frame_ready = false;
            }
            return false;
        }
        self.begin_host_gpu_frame()
    }

    fn begin_host_gpu_frame(&mut self) -> bool {
        let active = self
            .host_gpu
            .as_mut()
            .is_some_and(HostGpuRenderer::begin_frame);
        if self.host_gpu.is_some() && !active {
            log::warn!("rfvp GPU frame setup failed; reverting to CPU renderer");
            self.host_gpu.take();
        }
        active
    }

    fn finish_host_gpu_frame(&mut self) {
        // A deliberate CPU frame must retain its GPU cache for later frames.
        if !self.host_gpu_frame_active() {
            return;
        }
        let healthy = self
            .host_gpu
            .as_mut()
            .is_none_or(HostGpuRenderer::end_frame);
        if !healthy {
            log::error!("rfvp GPU frame failed; reverting to CPU renderer");
            let stride = self.framebuffer.stride() as u32;
            if let Some(renderer) = self.host_gpu.as_mut() {
                // Preserve every operation the bridge did accept before the
                // failure, so the one transition frame is not stale garbage.
                let _ = renderer.readback(self.framebuffer.pixels_mut(), stride);
            }
            self.host_gpu.take();
        }
    }

    fn prune_host_gpu_graphs(&mut self, graphs: &[GraphBuff]) {
        if let Some(renderer) = self.host_gpu.as_mut() {
            renderer.prune_graphs(graphs);
        }
    }

    fn host_gpu_frame_active(&self) -> bool {
        self.host_gpu
            .as_ref()
            .is_some_and(|renderer| renderer.frame_active)
    }

    fn try_host_gpu_quad(
        &mut self,
        v0: Vertex,
        v1: Vertex,
        v2: Vertex,
        v3: Vertex,
        texture: TextureRef<'_>,
    ) -> bool {
        self.host_gpu
            .as_mut()
            .is_some_and(|renderer| renderer.draw_quad([v0, v1, v2, v3], texture, self.additive))
    }

    pub(crate) fn host_gpu_texture(&self) -> Option<u64> {
        self.host_gpu
            .as_ref()
            .filter(|renderer| renderer.frame_ready && !renderer.frame_active)
            .map(|renderer| renderer.target)
            .filter(|target| *target != 0)
    }

    pub(crate) fn sync_host_gpu_framebuffer(&mut self) -> bool {
        let stride = self.framebuffer.stride() as u32;
        let format = self.framebuffer.format();
        match self.host_gpu.as_mut() {
            Some(renderer) if renderer.frame_active => false,
            Some(renderer) if renderer.frame_ready => {
                if !renderer.readback(self.framebuffer.pixels_mut(), stride) {
                    return false;
                }
                // The host callback always returns RGBA, regardless of the
                // software framebuffer's selected byte order.
                if format == PixelFormat::Bgra8 {
                    for pixel in self.framebuffer.pixels_mut().chunks_exact_mut(4) {
                        pixel.swap(0, 2);
                    }
                }
                true
            }
            _ => true,
        }
    }

    fn try_host_axis_quad(
        &mut self,
        top_left: Vec2,
        top_right: Vec2,
        bottom_left: Vec2,
        uv0: Vec2,
        uv1: Vec2,
        color: Vec4,
        texture: TextureRef<'_>,
    ) -> bool {
        if self.host_gpu_frame_active() {
            return false;
        }
        if top_left.x != bottom_left.x || top_left.y != top_right.y {
            return false;
        }
        let dx = top_right.x - top_left.x;
        let dy = bottom_left.y - top_left.y;
        if !top_left.is_finite() || !dx.is_finite() || !dy.is_finite() {
            return false;
        }
        if dx.abs() <= f32::EPSILON || dy.abs() <= f32::EPSILON {
            return true;
        }
        // Match the triangle rasterizer's pixel-center coverage, including
        // clipping and negative scales. A shared diagonal must be blended once.
        let first_x = ((top_left.x.min(top_right.x) - 0.5).ceil().max(0.0)) as u32;
        let first_y = ((top_left.y.min(bottom_left.y) - 0.5).ceil().max(0.0)) as u32;
        let end_x = ((top_left.x.max(top_right.x) - 0.5).floor() + 1.0)
            .clamp(0.0, self.framebuffer.width() as f32) as u32;
        let end_y = ((top_left.y.max(bottom_left.y) - 0.5).floor() + 1.0)
            .clamp(0.0, self.framebuffer.height() as f32) as u32;
        let du = (uv1.x - uv0.x) / dx;
        let dv = (uv1.y - uv0.y) / dy;
        for y in first_y..end_y {
            let v = uv0.y + (y as f32 + 0.5 - top_left.y) * dv;
            for x in first_x..end_x {
                let u = uv0.x + (x as f32 + 0.5 - top_left.x) * du;
                let src = self.sample_texture(texture, vec2(u, v)) * color;
                self.blend_pixel(x, y, src);
            }
        }
        true
    }
}

#[cfg(test)]
mod host_renderer_tests {
    use super::*;
    use std::ffi::c_void;
    use std::sync::{Mutex, OnceLock};

    #[derive(Debug, Default)]
    struct FakeGpuState {
        creates: Vec<(u32, u32, bool, [u8; 4])>,
        releases: Vec<u64>,
        clears: Vec<(u64, u32, HostGpuRect)>,
        draws: Vec<(u64, u64, u32, HostGpuRect, f32, u32)>,
        first_source_points: Vec<(f64, f64)>,
        begins: usize,
        ends: Vec<u64>,
        reads: Vec<(u64, usize, u32)>,
        read_pixel: Option<[u8; 4]>,
        fail_read: bool,
    }

    fn fake_gpu() -> &'static Mutex<FakeGpuState> {
        static STATE: OnceLock<Mutex<FakeGpuState>> = OnceLock::new();
        STATE.get_or_init(|| Mutex::new(FakeGpuState::default()))
    }

    fn fake_gpu_test_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: Mutex<()> = Mutex::new(());
        LOCK.lock().unwrap()
    }

    unsafe extern "C" fn fake_create(
        width: u32,
        height: u32,
        pixels: *const c_void,
        _stride: u32,
    ) -> u64 {
        let mut state = fake_gpu().lock().unwrap();
        let first_pixel = if pixels.is_null() {
            [0; 4]
        } else {
            *(pixels.cast::<[u8; 4]>())
        };
        state
            .creates
            .push((width, height, !pixels.is_null(), first_pixel));
        100 + state.creates.len() as u64 - 1
    }

    unsafe extern "C" fn fake_release(texture: u64) {
        fake_gpu().lock().unwrap().releases.push(texture);
    }

    unsafe extern "C" fn fake_update(
        _texture: u64,
        _pixels: *const c_void,
        _stride: u32,
        _rect: *const HostGpuRect,
    ) -> bool {
        true
    }

    unsafe extern "C" fn fake_clear(texture: u64, rgba: u32, rect: *const HostGpuRect) -> bool {
        fake_gpu()
            .lock()
            .unwrap()
            .clears
            .push((texture, rgba, *rect));
        true
    }

    unsafe extern "C" fn fake_draw(
        dst: u64,
        src: u64,
        triangles: u32,
        clip: *const HostGpuRect,
        _dst_points: *const HostGpuPoint,
        src_points: *const HostGpuPoint,
        opacity: f32,
        blend: u32,
    ) -> bool {
        let mut state = fake_gpu().lock().unwrap();
        state
            .draws
            .push((dst, src, triangles, *clip, opacity, blend));
        state
            .first_source_points
            .push(((*src_points).x, (*src_points).y));
        true
    }

    unsafe extern "C" fn fake_read(
        texture: u64,
        pixels: *mut c_void,
        size: usize,
        stride: u32,
    ) -> bool {
        let mut state = fake_gpu().lock().unwrap();
        state.reads.push((texture, size, stride));
        if state.fail_read {
            return false;
        }
        let value = state.read_pixel.unwrap_or([0x5a; 4]);
        for pixel in std::slice::from_raw_parts_mut(pixels.cast::<u8>(), size).chunks_exact_mut(4) {
            pixel.copy_from_slice(&value);
        }
        true
    }

    unsafe extern "C" fn fake_begin() -> u64 {
        fake_gpu().lock().unwrap().begins += 1;
        77
    }

    unsafe extern "C" fn fake_end(token: u64) -> bool {
        fake_gpu().lock().unwrap().ends.push(token);
        true
    }

    unsafe extern "C" fn fake_flush() -> bool {
        true
    }

    fn fake_callbacks() -> HostGpuCallbacks {
        HostGpuCallbacks {
            struct_size: std::mem::size_of::<HostGpuCallbacks>() as u32,
            api_version: 0x0100_0000,
            create_rgba: Some(fake_create),
            release_texture: Some(fake_release),
            update_rgba: Some(fake_update),
            clear_rgba: Some(fake_clear),
            draw_triangles: Some(fake_draw),
            read_rgba: Some(fake_read),
            begin_batch: Some(fake_begin),
            end_batch: Some(fake_end),
            flush: Some(fake_flush),
        }
    }

    #[test]
    fn host_gpu_is_lazy_batched_and_read_back_only_on_request() {
        let _guard = fake_gpu_test_lock();
        *fake_gpu().lock().unwrap() = FakeGpuState::default();
        {
            let mut renderer = SoftRenderer::new(8, 6, PixelFormat::Rgba8).unwrap();
            assert!(renderer.install_host_gpu(fake_callbacks()));
            assert_eq!(renderer.host_gpu_texture(), None);
            assert!(renderer.begin_host_gpu_frame());
            assert_eq!(renderer.host_gpu_texture(), None);
            renderer.fill_rect(1.0, 2.0, 4.0, 3.0, vec4(1.0, 1.0, 1.0, 0.5));
            renderer.fill_rect(5.0, 2.0, 3.0, 3.0, vec4(1.0, 1.0, 1.0, 0.5));
            let graph = GraphBuff::new();
            let image = DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
                2,
                2,
                image::Rgba([200, 100, 50, 128]),
            ));
            renderer
                .draw_textured_quad(
                    Mat4::from_translation(vec3(2.0, 0.0, 0.0)),
                    2.0,
                    2.0,
                    Vec2::ZERO,
                    Vec2::ONE,
                    vec4(0.5, 0.25, 1.0, 0.75),
                    TextureRef::Graph {
                        graph_id: 7,
                        graph: &graph,
                        image: &image,
                    },
                )
                .unwrap();
            renderer.finish_host_gpu_frame();
            assert_eq!(renderer.host_gpu_texture(), Some(100));

            let before_read = fake_gpu().lock().unwrap().reads.len();
            assert_eq!(before_read, 0);
            assert!(renderer.sync_host_gpu_framebuffer());
            assert!(renderer.framebuffer.pixels().iter().all(|v| *v == 0x5a));
        }

        let state = fake_gpu().lock().unwrap();
        assert_eq!(
            state.creates,
            vec![
                (8, 6, false, [0; 4]),
                (1, 1, true, [255, 255, 255, 255]),
                (2, 2, true, [100, 25, 50, 128]),
            ]
        );
        assert_eq!(state.begins, 1);
        assert_eq!(state.ends, vec![77]);
        assert_eq!(state.clears.len(), 1);
        assert_eq!(state.clears[0].0, 100);
        assert_eq!(state.clears[0].1, 0xff00_0000);
        assert_eq!(state.draws.len(), 2);
        assert_eq!(state.draws[0].0, 100);
        assert_eq!(state.draws[0].1, 101);
        assert_eq!(state.draws[0].2, 4);
        assert_eq!(state.draws[0].4, 0.5);
        assert_eq!(state.draws[0].5, 0x1001_0002);
        assert_eq!(state.draws[1].1, 102);
        assert_eq!(state.draws[1].2, 2);
        assert_eq!(state.draws[1].4, 0.75);
        assert_eq!(state.draws[1].5, 0x0401_0002);
        assert_eq!(state.first_source_points, vec![(0.5, 0.5), (0.5, 1.5)]);
        assert_eq!(state.reads, vec![(100, 8 * 6 * 4, 8 * 4)]);
        assert_eq!(state.releases, vec![102, 101, 100]);
    }

    #[test]
    fn host_gpu_additive_quads_use_srcalpha_one_and_split_batches() {
        let _guard = fake_gpu_test_lock();
        *fake_gpu().lock().unwrap() = FakeGpuState::default();
        let mut renderer = SoftRenderer::new(8, 6, PixelFormat::Rgba8).unwrap();
        renderer.install_host_gpu(fake_callbacks());
        assert!(renderer.begin_host_gpu_frame());
        renderer.additive = true;
        renderer
            .draw_textured_quad(
                Mat4::IDENTITY,
                4.0,
                6.0,
                Vec2::ZERO,
                Vec2::ONE,
                vec4(1.0, 1.0, 1.0, 0.5),
                TextureRef::White,
            )
            .unwrap();
        // Same texture, opacity and disjoint bounds would otherwise batch.
        renderer.fill_rect(4.0, 0.0, 4.0, 6.0, vec4(1.0, 1.0, 1.0, 0.5));
        renderer.finish_host_gpu_frame();
        let state = fake_gpu().lock().unwrap();
        assert_eq!(state.draws.len(), 2);
        assert_eq!(state.draws[0].5, 0x1000_0001);
        assert_eq!(state.draws[1].5, 0x1001_0002);
        assert_eq!(state.draws[0].4, 0.5);
        assert_eq!(state.draws[0].2, 2);
    }

    #[test]
    fn host_gpu_mask_dissolve_snapshots_then_presents_cpu_frames_and_resumes() {
        let _guard = fake_gpu_test_lock();
        *fake_gpu().lock().unwrap() = FakeGpuState {
            read_pixel: Some([40, 80, 120, 255]),
            ..Default::default()
        };
        for format in [PixelFormat::Rgba8, PixelFormat::Bgra8] {
            let mut renderer = SoftRenderer::new(8, 6, format).unwrap();
            renderer.install_host_gpu(fake_callbacks());
            let mut motion = MotionManager::new();
            let mut mask = GraphBuff::new();
            mask.load_from_buff([0, 0, 0, 128].repeat(8 * 6), 8, 6)
                .unwrap();
            motion.set_dissolve_mask_graph(mask);
            renderer.render_motion(&motion).unwrap();
            let target = renderer.host_gpu_texture().unwrap();
            let reads_before = fake_gpu().lock().unwrap().reads.len();
            motion.start_dissolve(100, DissolveType::MaskFadeIn);
            renderer.render_motion(&motion).unwrap();
            assert_eq!(renderer.host_gpu_texture(), None);
            assert!(renderer.host_gpu.is_some());
            assert_eq!(fake_gpu().lock().unwrap().reads.len(), reads_before + 1);
            let expected = match format {
                PixelFormat::Rgba8 => [40, 80, 120, 255],
                PixelFormat::Bgra8 => [120, 80, 40, 255],
            };
            for pixel in renderer.framebuffer.pixels().chunks_exact(4) {
                assert_eq!(pixel, &expected);
            }
            // Reading a CPU-owned frame must not overwrite it with the old GPU
            // texture. The next mask phase is fully transparent over black.
            motion.tick_dissolve(75);
            renderer.render_motion(&motion).unwrap();
            assert!(renderer.sync_host_gpu_framebuffer());
            for pixel in renderer.framebuffer.pixels().chunks_exact(4) {
                assert_eq!(pixel, &[0, 0, 0, 255]);
            }
            assert_eq!(fake_gpu().lock().unwrap().reads.len(), reads_before + 1);
            assert_eq!(renderer.host_gpu_texture(), None);
            motion.tick_dissolve(25);
            renderer.render_motion(&motion).unwrap();
            assert_eq!(renderer.host_gpu_texture(), Some(target));
        }
        let state = fake_gpu().lock().unwrap();
        assert_eq!(state.begins, 4);
        assert_eq!(state.ends.len(), 4);
        assert_eq!(state.reads.len(), 2);
    }

    #[test]
    fn host_gpu_failed_snapshot_does_not_capture_stale_cpu_pixels() {
        let _guard = fake_gpu_test_lock();
        *fake_gpu().lock().unwrap() = FakeGpuState::default();
        let mut renderer = SoftRenderer::new(4, 4, PixelFormat::Rgba8).unwrap();
        renderer.install_host_gpu(fake_callbacks());
        let mut motion = MotionManager::new();
        let mut mask = GraphBuff::new();
        mask.load_from_buff(vec![255; 4 * 4 * 4], 4, 4).unwrap();
        motion.set_dissolve_mask_graph(mask);
        renderer.render_motion(&motion).unwrap();
        renderer.framebuffer.clear_rgba(200, 100, 50, 255);
        fake_gpu().lock().unwrap().fail_read = true;
        motion.start_dissolve(100, DissolveType::MaskFadeInOut);
        renderer.render_motion(&motion).unwrap();
        assert!(renderer.host_gpu.is_none());
        assert!(renderer.mask_frame.image.is_none());
        assert_eq!(renderer.host_gpu_texture(), None);
        for pixel in renderer.framebuffer.pixels().chunks_exact(4) {
            assert_eq!(pixel, &[0, 0, 0, 255]);
        }
    }

    #[test]
    fn host_cpu_additive_axis_quad_preserves_destination_alpha() {
        for format in [PixelFormat::Rgba8, PixelFormat::Bgra8] {
            let mut renderer = SoftRenderer::new(4, 4, format).unwrap();
            renderer.framebuffer.clear_rgba(200, 20, 30, 77);
            renderer.additive = true;
            renderer
                .draw_textured_quad(
                    Mat4::IDENTITY,
                    4.0,
                    4.0,
                    Vec2::ZERO,
                    Vec2::ONE,
                    vec4(0.8, 0.4, 0.2, 0.5),
                    TextureRef::White,
                )
                .unwrap();
            let expected = match format {
                PixelFormat::Rgba8 => [255, 71, 56, 77],
                PixelFormat::Bgra8 => [56, 71, 255, 77],
            };
            for pixel in renderer.framebuffer.pixels().chunks_exact(4) {
                assert_eq!(pixel, &expected);
            }
        }
    }

    #[test]
    fn invisible_quads_skip_rasterization() {
        let mut renderer = SoftRenderer::new(16, 16, PixelFormat::Rgba8).unwrap();
        renderer.framebuffer.clear_rgba(9, 19, 29, 255);
        renderer.fill_rect(0.0, 0.0, 16.0, 16.0, vec4(1.0, 1.0, 1.0, 0.0));
        assert_eq!(renderer.stats.draw_calls, 0);
        for pixel in renderer.framebuffer.pixels().chunks_exact(4) {
            assert_eq!(pixel, &[9, 19, 29, 255]);
        }
    }

    #[test]
    fn translucent_quad_has_no_double_blended_diagonal() {
        let mut renderer = SoftRenderer::new(16, 16, PixelFormat::Rgba8).unwrap();
        renderer.framebuffer.clear_rgba(0, 0, 0, 255);
        renderer.fill_rect(0.0, 0.0, 16.0, 16.0, vec4(1.0, 1.0, 1.0, 0.5));
        for pixel in renderer.framebuffer.pixels().chunks_exact(4) {
            assert_eq!(pixel, &[128, 128, 128, 255]);
        }
    }

    #[test]
    fn axis_quad_matches_triangle_sampling_clipping_and_flips() {
        let image = DynamicImage::ImageRgba8(image::RgbaImage::from_fn(13, 11, |x, y| {
            image::Rgba([(x * 19) as u8, (y * 23) as u8, ((x + y) * 9) as u8, 255])
        }));
        let graph = GraphBuff::new();
        for format in [PixelFormat::Rgba8, PixelFormat::Bgra8] {
            for graph_id in [0, 4064] {
                for (x, y, w, h) in [
                    (0.0, 0.0, 16.0, 16.0),
                    (-3.3, 2.2, 20.5, 11.7),
                    (18.0, 17.0, -20.0, -19.0),
                    (40.0, 0.0, 4.0, 4.0),
                ] {
                    let mut actual = SoftRenderer::new(16, 16, format).unwrap();
                    let mut reference = SoftRenderer::new(16, 16, format).unwrap();
                    let texture = TextureRef::Graph {
                        graph_id,
                        graph: &graph,
                        image: &image,
                    };
                    let uv0 = vec2(0.13, 0.21);
                    let uv1 = vec2(0.87, 0.93);
                    let color = vec4(0.8, 0.9, 0.7, 1.0);
                    actual
                        .draw_textured_quad(
                            Mat4::from_translation(vec3(x, y, 0.0)),
                            w,
                            h,
                            uv0,
                            uv1,
                            color,
                            texture,
                        )
                        .unwrap();
                    let a = Vertex {
                        pos: vec2(x, y + h),
                        uv: vec2(uv0.x, uv1.y),
                        color,
                    };
                    let b = Vertex {
                        pos: vec2(x, y),
                        uv: uv0,
                        color,
                    };
                    let c = Vertex {
                        pos: vec2(x + w, y + h),
                        uv: uv1,
                        color,
                    };
                    let d = Vertex {
                        pos: vec2(x + w, y),
                        uv: vec2(uv1.x, uv0.y),
                        color,
                    };
                    reference.raster_triangle(a, b, c, texture);
                    reference.raster_triangle(c, b, d, texture);
                    for (a, b) in actual
                        .framebuffer
                        .pixels()
                        .iter()
                        .zip(reference.framebuffer.pixels())
                    {
                        assert!(a.abs_diff(*b) <= 1, "sampling mismatch {a} vs {b}");
                    }
                }
            }
        }
    }

    #[test]
    fn rotated_quad_uses_existing_triangle_path() {
        let mut renderer = SoftRenderer::new(16, 16, PixelFormat::Rgba8).unwrap();
        assert!(!renderer.try_host_axis_quad(
            vec2(1.0, 0.0),
            vec2(2.0, 1.0),
            vec2(0.0, 1.0),
            Vec2::ZERO,
            Vec2::ONE,
            Vec4::ONE,
            TextureRef::White
        ));
        assert!(renderer.framebuffer.pixels().iter().all(|v| *v == 0));
    }
}
