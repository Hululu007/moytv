import 'package:flutter/material.dart';

enum PlayerBackAction {
  closePanel,
  exitPageFullscreen,
  exitFullscreen,
  backToList,
  backOnce,
  toHome,
}

PlayerBackAction resolvePlayerBackAction({
  required bool panelOpen,
  required bool pageFullscreen,
  required bool fullscreen,
  required bool television,
  required bool isFirstRoute,
}) {
  if (panelOpen) return PlayerBackAction.closePanel;
  if (television) return PlayerBackAction.backOnce;
  if (pageFullscreen) return PlayerBackAction.exitPageFullscreen;
  if (fullscreen) return PlayerBackAction.exitFullscreen;
  if (isFirstRoute) return PlayerBackAction.toHome;
  return PlayerBackAction.backToList;
}

bool isBackToListStop(Route<dynamic> route) {
  final name = route.settings.name;
  return name != 'player' && name != 'detail';
}
