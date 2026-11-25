import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const AetherPlayerApp());

class AetherPlayerApp extends StatelessWidget {
  const AetherPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aether ONS Preview',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFAB9CF7),
      ),
      home: const OnsPlayerPage(),
    );
  }
}

// Event values match engine_input_event_type_t in the shared engine API.
enum _Input {
  down(1),
  move(2),
  up(3),
  scroll(4),
  keyDown(5),
  keyUp(6);

  const _Input(this.value);
  final int value;
}

class OnsPlayerPage extends StatefulWidget {
  const OnsPlayerPage({super.key});

  @override
  State<OnsPlayerPage> createState() => _OnsPlayerPageState();
}

class _OnsPlayerPageState extends State<OnsPlayerPage> {
  static const _platform = MethodChannel('aether/ons_player');
  static final _virtualKeys = {
    LogicalKeyboardKey.backspace: 0x08,
    LogicalKeyboardKey.tab: 0x09,
    LogicalKeyboardKey.enter: 0x0D,
    LogicalKeyboardKey.numpadEnter: 0x0D,
    LogicalKeyboardKey.shiftLeft: 0xA0,
    LogicalKeyboardKey.shiftRight: 0xA1,
    LogicalKeyboardKey.controlLeft: 0xA2,
    LogicalKeyboardKey.controlRight: 0xA3,
    LogicalKeyboardKey.altLeft: 0xA4,
    LogicalKeyboardKey.altRight: 0xA5,
    LogicalKeyboardKey.escape: 0x1B,
    LogicalKeyboardKey.space: 0x20,
    LogicalKeyboardKey.pageUp: 0x21,
    LogicalKeyboardKey.pageDown: 0x22,
    LogicalKeyboardKey.end: 0x23,
    LogicalKeyboardKey.home: 0x24,
    LogicalKeyboardKey.arrowLeft: 0x25,
    LogicalKeyboardKey.arrowUp: 0x26,
    LogicalKeyboardKey.arrowRight: 0x27,
    LogicalKeyboardKey.arrowDown: 0x28,
    LogicalKeyboardKey.insert: 0x2D,
    LogicalKeyboardKey.delete: 0x2E,
  };

  final _gameFocus = FocusNode();
  final _heldKeys = <int>{};
  final _pointerButtons = <int, int>{};

  int? _textureId;
  Size? _frameSize;
  String? _gameTitle;
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _platform.setMethodCallHandler(_onNativeEvent);
  }

  @override
  void dispose() {
    _platform.setMethodCallHandler(null);
    _gameFocus.dispose();
    super.dispose();
  }

  Future<void> _onNativeEvent(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'frameSize':
        if (_textureId == null && !_busy) return;
        final size = call.arguments as Map<Object?, Object?>;
        setState(() {
          _frameSize = Size(
            (size['width'] as num).toDouble(),
            (size['height'] as num).toDouble(),
          );
        });
        _gameFocus.requestFocus();
      case 'ended':
        setState(() {
          _clearGame();
          _message = call.arguments as String?;
        });
    }
  }

  void _clearGame() {
    _textureId = null;
    _frameSize = null;
    _gameTitle = null;
    _heldKeys.clear();
    _pointerButtons.clear();
  }

  Future<void> _chooseGame() async {
    if (_busy || _textureId != null) return;
    setState(() => _busy = true);
    try {
      final path = await _platform.invokeMethod<String>('chooseFolder');
      if (path == null || !mounted) return;
      final result = await _platform.invokeMapMethod<String, Object?>(
        'open',
        path,
      );
      if (!mounted || result == null) return;
      setState(() {
        _textureId = result['textureId'] as int;
        _gameTitle = result['title'] as String;
        _message = null;
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeGame() async {
    if (_busy || _textureId == null) return;
    setState(() => _busy = true);
    try {
      await _platform.invokeMethod<void>('close');
      if (mounted) setState(_clearGame);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _sendInput(_Input input, Map<String, Object> values) {
    if (_textureId == null) return;
    unawaited(
      _platform.invokeMethod<void>('input', {'type': input.value, ...values}),
    );
  }

  int? _virtualKey(LogicalKeyboardKey key) {
    final virtualKey = _virtualKeys[key];
    if (virtualKey != null) return virtualKey;

    final label = key.keyLabel.toUpperCase();
    if (label.length != 1) return null;
    final code = label.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A)
        ? code
        : null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = _virtualKey(event.logicalKey);
    if (key == null || _frameSize == null) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      if (_heldKeys.remove(key)) _sendInput(_Input.keyUp, {'key': key});
    } else if (event is KeyDownEvent) {
      if (HardwareKeyboard.instance.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      if (_heldKeys.add(key)) _sendInput(_Input.keyDown, {'key': key});
    }
    return KeyEventResult.handled;
  }

  void _onFocusChanged(bool focused) {
    if (focused) return;
    for (final key in _heldKeys) {
      _sendInput(_Input.keyUp, {'key': key});
    }
    _heldKeys.clear();
  }

  Widget _gameView() {
    final size = _frameSize!;
    return AspectRatio(
      aspectRatio: size.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void sendPointer(_Input input, PointerEvent event, int button) {
            final local = event.localPosition;
            _sendInput(input, {
              'pointer': event.pointer,
              'x': (local.dx / constraints.maxWidth * size.width).clamp(
                0,
                size.width - 1,
              ),
              'y': (local.dy / constraints.maxHeight * size.height).clamp(
                0,
                size.height - 1,
              ),
              'button': button,
              if (event is PointerCancelEvent) 'cancelled': true,
              if (event is PointerScrollEvent) 'scroll': -event.scrollDelta.dy,
            });
          }

          void releasePointer(PointerEvent event) {
            final button = _pointerButtons.remove(event.pointer);
            if (button != null) sendPointer(_Input.up, event, button);
          }

          return Focus(
            focusNode: _gameFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            onFocusChange: _onFocusChanged,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                _gameFocus.requestFocus();
                final button = (event.buttons & kSecondaryMouseButton) != 0
                    ? 1
                    : 0;
                _pointerButtons[event.pointer] = button;
                sendPointer(_Input.down, event, button);
              },
              onPointerUp: releasePointer,
              onPointerCancel: releasePointer,
              onPointerMove: (event) => sendPointer(_Input.move, event, 0),
              onPointerHover: (event) => sendPointer(_Input.move, event, 0),
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  sendPointer(_Input.scroll, event, 0);
                }
              },
              child: Texture(textureId: _textureId!),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inGame = _textureId != null;
    return Scaffold(
      appBar: AppBar(
        title: _gameTitle == null ? null : Text(_gameTitle!),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: inGame
                ? TextButton.icon(
                    onPressed: _busy ? null : _closeGame,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Close Game'),
                  )
                : FilledButton.icon(
                    onPressed: _busy ? null : _chooseGame,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open Game'),
                  ),
          ),
        ],
      ),
      body: ColoredBox(
        color: inGame ? Colors.black : const Color(0xFF17151B),
        child: Center(
          child: inGame
              ? (_frameSize == null
                    ? const CircularProgressIndicator.adaptive(
                        semanticsLabel: 'Opening game',
                      )
                    : _gameView())
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _message ?? 'Choose an ONScripter game folder.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
        ),
      ),
    );
  }
}
