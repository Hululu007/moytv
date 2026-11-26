# 直播页「+」按钮挪右下角（2026-11-26）

用户 2026-11-26 15:09 在主聊发直播页截图下令：「直播+放右下角」——直播页左下角那个蓝色圆形「+」（导入直播源）按钮，挪到右下角。

- 基线：v68 组装树 ed69442；工作树 ~/workspace/moyi_live_plus_pos_20261126，分支 live-plus-pos。只本地提交，未推仓、未构建。
- 改动只落两版共有部分（lib/live_screen.dart 直播页本体），带站点版与空壳版同带。

## 改了哪一处

`lib/live_screen.dart` 的 `_importButton`（直播页「+」导入钮，v67「直播左下角 + 导入」批落的码）：

- `Positioned(left: 12, bottom: 12)` → `Positioned(right: 12, bottom: 12)`，只挪位置。
- 按钮本体（48×48 圆形、主题主色、阴影、Tooltip「导入直播源」）、点击行为（`_showImportMenu` 底部菜单：导入本地文件 / 添加远程链接）、导入流程（M3uSubscriptionService + LocalStore.syncM3uSubscriptions，与导入中心同一套）、防重复点 `_importing` —— 一概未动。
- 按钮上方的文档注释同步由「左下角」改「右下角」并注明改令出处。

连带同步（仅文字与断言，无行为变化）：

- `test/live_import_epg_test.dart`：用例名与文件头注释改「右下角」；位置断言由 `before.left == 12` 改为 `before.right == 390 - 12`（底边距断言 `844 - 12` 不变）。
- `test/preview_live_import_add_test.dart`、`test/preview_live_import_menu_test.dart`：文件头注释与预览横幅文案里的「左下角」改「右下角」。

## 位置自校

- 边距规格与原来镜像一致：右 12、底 12，48×48 不变。
- 页面内另一个 Positioned 是播放面左上角的频道号角标（left:4, top:4），与右下角不冲突；页面无其他右下角浮动元素。
- 预览图核过：按钮在列表区右下角悬浮，不挡信息行（页面顶部）、不挡播放面；与原来在左下角时一样盖在可滚动的频道列表之上（列表可从其下方滑过），属原有悬浮形态的镜像。

## 预览图（preview/ 下，演示数据、播放画面为占位块）

- 改前：[live_import_add_before.png](sandbox://workspace/moyi_live_plus_pos_20261126/preview/live_import_add_before.png)（「+」在左下角，与用户截图一致）
- 改后：[live_import_add_after.png](sandbox://workspace/moyi_live_plus_pos_20261126/preview/live_import_add_after.png)（「+」在右下角）

## 验证

- `test/live_import_epg_test.dart`：21/21 全过，含更新后的「「+」固定右下角：滚列表不动，点开菜单两项齐」（滚动后位置不变、菜单两项齐、导入全链在内）。
- 其余引用 live_screen 的普通测试 9 个文件（live_layout / live_subscription_dual_entry / live_tv_redesign / live_resume / live_fullscreen_exit / live_drm_exo / bottom_tab_nav / source_picker_wiring / vod_return_zone）合跑：仅 1 条失败——`bottom_tab_nav_test.dart：短剧首页 requestedTab 直达女优库页`；已用 git stash 在干净基线 ed69442 上复跑同一文件，同条同样失败，属基线既有失败（与演员库入口换页有关，非本批引入），**本批 0 新增失败**。
- analyze（改动 4 文件）：0 错 0 警；仅 6 条既有 info（material 导入弃用提示 4 条、预览测试 avoid_print 2 条），与基线一致。
- 测试一律 `--no-pub`、TMPDIR 指工作树内目录；预览测试单跑、PNG 落地后杀挂尾进程（既定口径）。

## 手机终验（一句话）

装含本批的新版后打开直播页：左下角的蓝色「+」应已挪到右下角，点开仍是「导入本地文件 / 添加远程链接」菜单，导入照常能用。
