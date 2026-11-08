import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

double diagonalDragAngleFromVertical(Offset total) {
  if (total == Offset.zero) {
    return 90;
  }
  return math.atan2(total.dx.abs(), total.dy.abs()) * 180 / math.pi;
}

bool shouldClaimDiagonalDrag(Offset total) {
  if (total.distance < 14) {
    return false;
  }
  final angle = diagonalDragAngleFromVertical(total);
  return angle >= 40 && angle <= 65;
}

class FeedDiagonalDragRecognizer extends OneSequenceGestureRecognizer {
  FeedDiagonalDragRecognizer({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    this.isBlocked,
    super.debugOwner,
  });

  ValueChanged<DragStartDetails> onStart;
  ValueChanged<DragUpdateDetails> onUpdate;
  ValueChanged<DragEndDetails> onEnd;
  VoidCallback onCancel;
  bool Function()? isBlocked;

  @override
  String get debugDescription => 'diagonal feed drag';

  int? _pointer;
  OffsetPair? _downPosition;
  Offset _total = Offset.zero;
  VelocityTracker? _velocityTracker;
  bool _claimed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) {
      return;
    }
    _pointer = event.pointer;
    _downPosition = OffsetPair(
      local: event.localPosition,
      global: event.position,
    );
    _total = Offset.zero;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _claimed = false;
    startTrackingPointer(event.pointer, event.transform);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    if (event is PointerMoveEvent) {
      _velocityTracker?.addPosition(event.timeStamp, event.position);
      if (_claimed) {
        onUpdate(
          DragUpdateDetails(
            sourceTimeStamp: event.timeStamp,
            delta: Offset(0, event.localDelta.dy),
            primaryDelta: event.localDelta.dy,
            globalPosition: event.position,
            localPosition: event.localPosition,
          ),
        );
        return;
      }
      _total += event.localDelta;
      if (isBlocked?.call() == true) {
        resolve(GestureDisposition.rejected);
        return;
      }
      if (shouldClaimDiagonalDrag(_total)) {
        _claimed = true;
        resolve(GestureDisposition.accepted);
        final down = _downPosition;
        if (down != null) {
          onStart(
            DragStartDetails(
              sourceTimeStamp: event.timeStamp,
              globalPosition: down.global,
              localPosition: down.local,
              kind: event.kind,
            ),
          );
        }
      }
    } else if (event is PointerUpEvent) {
      if (_claimed) {
        final velocity = _velocityTracker?.getVelocity();
        onEnd(
          DragEndDetails(
            primaryVelocity: velocity?.pixelsPerSecond.dy ?? 0,
            velocity: velocity ?? Velocity.zero,
          ),
        );
      } else {
        resolve(GestureDisposition.rejected);
      }
      _reset(event.pointer);
    } else if (event is PointerCancelEvent) {
      if (_claimed) {
        onCancel();
      }
      _reset(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == _pointer) {
      _reset(pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _reset(pointer);
  }

  void _reset(int pointer) {
    if (_pointer != pointer) {
      return;
    }
    _pointer = null;
    _downPosition = null;
    _total = Offset.zero;
    _velocityTracker = null;
    _claimed = false;
    stopTrackingPointer(pointer);
  }
}
