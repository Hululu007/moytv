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
Future<List<Out>> fanoutOrdered<In, Out>(
  List<In> inputs,
  Future<Out> Function(In input) run, {
  int concurrency = 6,
}) async {
  if (inputs.isEmpty) return <Out>[];
  final workers = min(concurrency < 1 ? 1 : concurrency, inputs.length);
  final results = List<Out?>.filled(inputs.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= inputs.length) return;
      results[index] = await run(inputs[index]);
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  return [for (final result in results) result as Out];
}

/// 有界并发扇出（逐个回调版）：与 [fanoutOrdered] 同款有界并发，
/// 但每项完成时立即调 [onResult]（按完成顺序），不等全部跑完；
/// 返回的 Future 在全部任务结束后完成。
///
/// 全局搜索渐进显示用：先回的站先上屏，慢站不拖住已出的结果。
/// [run] 抛错的约定与 [fanoutOrdered] 相同：错误向上传播、其余
/// 在途任务继续跑完但结果被丢弃；需要单站失败隔离的调用方应
/// 在 [run] 内部自行 try/catch 后返回空结果。
Future<void> fanoutEach<In, Out>(
  List<In> inputs,
  Future<Out> Function(In input) run, {
  required void Function(In input, Out result) onResult,
  int concurrency = 6,
}) async {
  if (inputs.isEmpty) return;
  final workers = min(concurrency < 1 ? 1 : concurrency, inputs.length);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= inputs.length) return;
      final result = await run(inputs[index]);
      onResult(inputs[index], result);
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
}
