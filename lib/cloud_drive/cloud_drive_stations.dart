/// 网盘站点注册：登录后的网盘作为“站”进站点列表。
///
/// 只有登录后的网盘才注册（未登录的站点了也是死入口，登录中心是
/// 唯一入口）；退出/清除凭证后取消注册。注册表挂在 SourceSite 的
/// 静态表上，与导入配置的注册表分开，删配置不影响网盘站。
library;

import '../models.dart';
import 'cloud_credential_store.dart';
import 'cloud_providers.dart';

class CloudDriveStations {
  /// 按当前登录状态刷新注册表（启动时 + 每次登录/退出后调用）。
  static void refresh(CloudCredentialStore store) {
    final loggedIn = store.loggedInProviderIds(cloudDriveDisplayNames.keys);
    SourceSite.cloudDriveSites.clear();
    for (final id in loggedIn) {
      final siteId = 'cloud:$id';
      SourceSite.cloudDriveSites[siteId] = SourceSite(
        siteId,
        cloudDriveDisplayNames[id] ?? id,
        '网盘站源',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originBuiltin,
      );
    }
  }

  /// 当前已注册的网盘站。
  static List<SourceSite> get stations =>
      SourceSite.cloudDriveSites.values.toList();
}
