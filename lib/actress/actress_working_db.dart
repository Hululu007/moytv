import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 演员库内部工作库文件名（2026-11-25 用户令：只留 .sql 导入）。
///
/// 内部工作库是 .sql 导入落成的库，演员库只读它；MYTV/db/ 下
/// 用户放的 .db 文件从此不再被读（那条老路已删）。文件名沿用
/// 老的 `女优库.db`，只换落点：从 MYTV/db 搬到应用私有目录。
const actressWorkingDbFileName = '女优库.db';

/// 内部工作库路径：应用私有 documents 目录下的 `女优库.db`。
///
/// 只有 .sql 导入能写它（临时库改名顶替，见 ActressSqlImporter）。
/// 不做自动迁移：手机上现有的 MYTV/db/女优库.db 不自动拷过来，
/// 新版装好后演员库先是空的，提示导入 .sql，一次导入即恢复。
/// documents 目录解析失败时回系统临时目录（只作路径兜底，
/// 导入器会在换库前校验，写不进去会报换库失败）。
Future<String> actressWorkingDbPath() async {
  Directory docs;
  try {
    docs = await getApplicationDocumentsDirectory();
  } catch (_) {
    docs = Directory.systemTemp;
  }
  return path.join(docs.path, actressWorkingDbFileName);
}
