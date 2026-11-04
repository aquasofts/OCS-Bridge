import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'app_log.dart';

class AuditScope extends InheritedWidget {
  const AuditScope({super.key, required this.log, required super.child});
  final AppLog? log;
  static AppLog? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AuditScope>()?.log;
  @override
  bool updateShouldNotify(AuditScope oldWidget) => log != oldWidget.log;
}

/// Observes only this application's input. Never consumes input events.
class InteractionAudit {
  InteractionAudit(this.log);
  final AppLog log;
  TextEditingController? _controller;
  String? _label;
  TextEditingValue? _lastValue;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    HardwareKeyboard.instance.addHandler(_key);
    FocusManager.instance.addListener(_focus);
    _focus();
  }

  void _pointer(PointerEvent e) {
    log.write('interaction', 'input.pointer', {
      'type': e.runtimeType.toString(),
      'pointer': e.pointer,
      'device': e.device,
      'viewId': e.viewId,
      'kind': e.kind.name,
      'timestampUs': e.timeStamp.inMicroseconds,
      'position': [e.position.dx, e.position.dy],
      'localPosition': [e.localPosition.dx, e.localPosition.dy],
      'delta': [e.delta.dx, e.delta.dy],
      'buttons': e.buttons,
      'down': e.down,
      'pressure': e.pressure,
      'pressureMin': e.pressureMin,
      'pressureMax': e.pressureMax,
      'distance': e.distance,
      'distanceMax': e.distanceMax,
      'size': e.size,
      'radiusMajor': e.radiusMajor,
      'radiusMinor': e.radiusMinor,
      'orientation': e.orientation,
      'tilt': e.tilt,
      'obscured': e.obscured,
      'synthesized': e.synthesized,
      'platformData': e.platformData,
      if (e is PointerScrollEvent)
        'scrollDelta': [e.scrollDelta.dx, e.scrollDelta.dy],
      if (e is PointerPanZoomUpdateEvent)
        'panZoom': {
          'pan': [e.pan.dx, e.pan.dy],
          'scale': e.scale,
          'rotation': e.rotation,
        },
      'focusedField': _label,
      if (e is PointerDownEvent ||
          e is PointerUpEvent ||
          e is PointerScrollEvent)
        'hitPath': _hitPath(e),
    });
  }

  List<Map<String, dynamic>> _hitPath(PointerEvent e) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(result, e.position, e.viewId);
    return result.path.map((entry) {
      final target = entry.target;
      return <String, dynamic>{
        'type': target.runtimeType.toString(),
        if (target is RenderParagraph) 'text': target.text.toPlainText(),
        if (target is RenderSemanticsAnnotations)
          'semantics': {
            'label': target.properties.label,
            'hint': target.properties.hint,
            'value': target.properties.value,
            'tooltip': target.properties.tooltip,
            'button': target.properties.button,
            'textField': target.properties.textField,
            'enabled': target.properties.enabled,
          },
      };
    }).toList();
  }

  bool _key(KeyEvent e) {
    final keyboard = HardwareKeyboard.instance;
    log.write('interaction', 'input.key', {
      'type': e.runtimeType.toString(),
      'timestampUs': e.timeStamp.inMicroseconds,
      'logicalKeyId': e.logicalKey.keyId,
      'logicalKey': e.logicalKey.keyLabel,
      'physicalKey': e.physicalKey.debugName,
      'usbHidUsage': e.physicalKey.usbHidUsage,
      'character': e.character,
      'synthesized': e.synthesized,
      'shift': keyboard.isShiftPressed,
      'control': keyboard.isControlPressed,
      'alt': keyboard.isAltPressed,
      'meta': keyboard.isMetaPressed,
      'focusedField': _label,
    });
    return false;
  }

  void _focus() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    final state = context?.findAncestorStateOfType<EditableTextState>();
    final controller = state?.widget.controller;
    _controller?.removeListener(_text);
    _controller = controller;
    _label =
        context
            ?.findAncestorWidgetOfExactType<TextField>()
            ?.decoration
            ?.labelText ??
        focus?.debugLabel;
    _lastValue = null;
    log.write('interaction', 'input.focus', {
      'focus': focus?.debugLabel,
      'field': _label,
      'widget': context?.widget.runtimeType.toString(),
      'editable': state != null,
      'obscureText': state?.widget.obscureText,
    });
    _controller?.addListener(_text);
    _text();
  }

  void _text() {
    final value = _controller?.value;
    if (value == null || value == _lastValue) return;
    final previous = _lastValue;
    _lastValue = value;
    log.write('interaction', 'input.text', {
      'field': _label,
      'controller': _controller.hashCode,
      'previousText': previous?.text,
      'text': value.text,
      'selection': {
        'base': value.selection.baseOffset,
        'extent': value.selection.extentOffset,
        'affinity': value.selection.affinity.name,
        'directional': value.selection.isDirectional,
      },
      'composing': {'start': value.composing.start, 'end': value.composing.end},
    });
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    HardwareKeyboard.instance.removeHandler(_key);
    FocusManager.instance.removeListener(_focus);
    _controller?.removeListener(_text);
  }
}
