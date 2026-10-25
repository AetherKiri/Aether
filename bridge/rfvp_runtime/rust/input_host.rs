// SPDX-License-Identifier: MPL-2.0
use crate::subsystem::resources::input_manager::InputManager;

#[derive(Clone, Copy)]
struct PointerEvent {
    kind: u32,
    x: i32,
    y: i32,
    button: i32,
    wheel: i32,
}

#[derive(Default)]
struct HostPointerInput {
    pending: VecDeque<PointerEvent>,
    pressed: u8,
}

impl HostPointerInput {
    fn enqueue(&mut self, event: PointerEvent) -> Result<()> {
        if event.kind == 2 && self.pending.back().is_some_and(|last| last.kind == 2) {
            *self.pending.back_mut().unwrap() = event;
            return Ok(());
        }
        ensure!(self.pending.len() < 4096, "rfvp pointer input queue is full");
        self.pending.push_back(event);
        Ok(())
    }

    fn position(input: &mut InputManager, event: PointerEvent, size: (u32, u32)) {
        input.notify_mouse_move(event.x, event.y);
        input.set_mouse_in(event.x >= 0 && event.y >= 0
            && event.x < size.0 as i32 && event.y < size.1 as i32);
    }

    fn apply_frame(&mut self, input: &mut InputManager, size: (u32, u32)) {
        // A short touch can deliver both edges between VM ticks. FVP sliders
        // update their preview, then skip the setting callback if InputGetUp
        // is already set. Preserve each button transition for a separate tick.
        let mut changed = 0u8;
        while let Some(event) = self.pending.front().copied() {
            let bit = 1 << u8::from(event.button == 1);
            let transition = matches!(event.kind, 1 | 3)
                && (self.pressed & bit != 0) != (event.kind == 1);
            if transition && changed & bit != 0 {
                if event.kind == 3 {
                    // Keep the final release position available to this tick's
                    // drag callback without publishing the release edge yet.
                    Self::position(input, event, size);
                }
                break;
            }
            self.pending.pop_front();
            Self::position(input, event, size);
            let button = if event.button == 1 { KeyCode::MouseRight } else { KeyCode::MouseLeft };
            match event.kind {
                1 => input.notify_mouse_down(button),
                3 => input.notify_mouse_up(button),
                4 => input.notify_mouse_wheel(event.wheel),
                _ => (),
            }
            if transition {
                changed |= bit;
                if event.kind == 1 { self.pressed |= bit; }
                else { self.pressed &= !bit; }
            }
        }
    }

    fn cancel(&mut self, input: &mut InputManager) {
        self.pending.clear();
        self.pressed = 0;
        input.cancel_host_input();
    }
}

#[cfg(test)]
mod host_pointer_tests {
    use super::*;

    fn event(kind: u32, x: i32) -> PointerEvent {
        PointerEvent { kind, x, y: 20, button: 0, wheel: 0 }
    }

    fn frame(queue: &mut HostPointerInput, input: &mut InputManager) {
        queue.apply_frame(input, (100, 100));
        input.begin_frame();
    }

    #[test]
    fn short_click_keeps_press_and_release_in_distinct_vm_frames() {
        let mut input = InputManager::new();
        let mut queue = HostPointerInput::default();
        queue.enqueue(event(1, 10)).unwrap();
        queue.enqueue(event(3, 30)).unwrap();
        frame(&mut queue, &mut input);
        assert_ne!(input.get_input_down() & (1 << 4), 0);
        assert_ne!(input.get_input_state() & (1 << 4), 0);
        assert_eq!(input.get_input_up() & (1 << 4), 0);
        assert_eq!(input.get_cursor_x(), 30);
        frame(&mut queue, &mut input);
        assert_eq!(input.get_input_down() & (1 << 4), 0);
        assert_eq!(input.get_input_state() & (1 << 4), 0);
        assert_ne!(input.get_input_up() & (1 << 4), 0);
        frame(&mut queue, &mut input);
        assert_eq!(input.get_input_up(), 0);
    }

    #[test]
    fn repeated_short_clicks_preserve_order_and_positions() {
        let mut input = InputManager::new();
        let mut queue = HostPointerInput::default();
        input.set_click(0);
        for x in [10, 30, 50] {
            queue.enqueue(event(1, x)).unwrap();
            queue.enqueue(event(3, x)).unwrap();
        }
        for x in [10, 30, 50] {
            frame(&mut queue, &mut input);
            assert_eq!(input.get_cursor_x(), x);
            assert_ne!(input.get_input_down() & (1 << 4), 0);
            assert!(input.get_event().is_none());
            frame(&mut queue, &mut input);
            assert_eq!(input.get_event().unwrap().get_x(), x);
            assert_ne!(input.get_input_up() & (1 << 4), 0);
        }
        assert!(queue.pending.is_empty());
    }

    #[test]
    fn cancellation_drops_queued_clicks_and_held_buttons() {
        let mut input = InputManager::new();
        let mut queue = HostPointerInput::default();
        queue.enqueue(event(1, 10)).unwrap();
        queue.enqueue(event(3, 10)).unwrap();
        frame(&mut queue, &mut input);
        queue.cancel(&mut input);
        frame(&mut queue, &mut input);
        assert_eq!(input.get_input_down(), 0);
        assert_eq!(input.get_input_up(), 0);
        assert_eq!(input.get_input_state(), 0);
        assert!(input.get_event().is_none());
    }
}
