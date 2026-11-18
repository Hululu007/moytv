import 'dart:math';

/// 有界并发扇出：对 [inputs] 逐个跑 [run]，同时在途不超过 [concurrency] 个，
/// 返回结果按输入顺序排列（与各任务完成顺序无关）。
///
/// 搜索聚合（Go 核 nativeSearchAcross、阅读搜索、jar/py/js 混合搜索）都用
/// 同一款：无界 Future.wait 会把几十个站源一次全打出去，挤占 py 桥与
/// 网络；串行 for-await 则把各站耗时加总，慢站拖垮整轮搜索。有界并发
/// + 定序返回兼顾两者。
///
/// [run] 抛错时该 worker 的错误会向上传播、其余在途任务继续跑完但结果
/// 被丢弃；需要“单站失败不拖垮整轮”语义的调用方应在 [run] 内部自行
/// try/catch 后返回空结果（搜索聚合两处都已如此）。
///
/// [shouldStop]（O2 真取消）：worker 每次取新任务前检查，返回 true
/// 时不再发起后续任务、在途任务跑完后即收尾；取消后返回的 Future
/// 正常完成（绝不挂起），只回已完成的结果（按输入顺序，列表可能
/// 短于输入）。不传时行为与旧版一字不差。
Future<List<Out>> fanoutOrdered<In, Out>(
  List<In> inputs,
  Future<Out> Function(In input) run, {
  int concurrency = 6,
  bool Function()? shouldStop,
}) async {
  if (inputs.isEmpty) return <Out>[];
  final workers = min(concurrency < 1 ? 1 : concurrency, inputs.length);
  final results = List<Out?>.filled(inputs.length, null);
  final done = List<bool>.filled(inputs.length, false);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      if (shouldStop != null && shouldStop()) return;
      final index = next++;
      if (index >= inputs.length) return;
      results[index] = await run(inputs[index]);
      done[index] = true;
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  return [
    for (var i = 0; i < results.length; i++)
      if (done[i]) results[i] as Out,
  ];
}

/// 有界并发扇出（逐个回调版）：与 [fanoutOrdered] 同款有界并发，
/// 但每项完成时立即调 [onResult]（按完成顺序），不等全部跑完；
/// 返回的 Future 在全部任务结束后完成。
///
/// 全局搜索渐进显示用：先回的站先上屏，慢站不拖住已出的结果。
/// [run] 抛错的约定与 [fanoutOrdered] 相同：错误向上传播、其余
/// 在途任务继续跑完但结果被丢弃；需要单站失败隔离的调用方应
/// 在 [run] 内部自行 try/catch 后返回空结果。
///
/// [shouldStop]（O2 真取消）：worker 每次取新任务前检查，返回 true
/// 时不再发起后续任务；在途任务跑完、回调完后 Future 正常完成
/// （绝不挂起）。在途任务完成后的 [onResult] 照常回调，调用方
/// 用代次 guard 拦过期写回。
Future<void> fanoutEach<In, Out>(
  List<In> inputs,
  Future<Out> Function(In input) run, {
  required void Function(In input, Out result) onResult,
  int concurrency = 6,
  bool Function()? shouldStop,
}) async {
  if (inputs.isEmpty) return;
  final workers = min(concurrency < 1 ? 1 : concurrency, inputs.length);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      if (shouldStop != null && shouldStop()) return;
      final index = next++;
      if (index >= inputs.length) return;
      final result = await run(inputs[index]);
      onResult(inputs[index], result);
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
}
