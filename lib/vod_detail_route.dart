enum VodOpenAction { detail, directPlayback }

VodOpenAction vodOpenAction({required bool isVodZone, required bool resume}) {
  return VodOpenAction.directPlayback;
}
