from base.spider import BaseSpider


class Spider(BaseSpider):
    def getName(self):
        return "base_import"

    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        return {"class": [{"type_id": "1", "type_name": "分类一"}],
                "list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def homeVideoContent(self):
        return {"list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

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
