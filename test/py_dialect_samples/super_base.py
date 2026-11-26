from base.spider import Spider


class Spider(Spider):
    # 老壳方言形态（2026-11-26 巨型聚合蜘蛛实报）：init 第一行就
    # super().init(extend)，homeContent 也先取 super() 结果再加工；
    # 桩基类缺合同方法时整站死在 init。另故意不写 homeVideoContent，
    # 走仅播放（playOnly）放行口径，其余核心方法齐全。
    def getName(self):
        return "super_base"

    def init(self, extend=""):
        super().init(extend)
        self.headers = {"User-Agent": "test"}

    def homeContent(self, filter=None):
        result = super().homeContent(filter)
        result["class"] = [{"type_id": "1", "type_name": "分类一"}]
        result["list"] = [{"vod_id": "v1", "vod_name": "片一",
                           "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]
        return result

    def categoryContent(self, tid, pg, filter, extend):
        return {"page": pg, "pagecount": 1,
                "list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def detailContent(self, ids):
        return {"list": [{"vod_id": ids[0], "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_play_from": "线路1",
                          "vod_play_url": "第1集$play1"}]}

    def searchContent(self, key, quick, pg):
        return {"list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": "http://x/v1.m3u8",
                "header": {"User-Agent": "test"}}
