class Spider:
    def getName(self):
        return "arity_dialect"

    def init(self):
        pass

    def homeContent(self):
        return {"class": [{"type_id": "1", "type_name": "分类一"}],
                "list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def homeVideoContent(self):
        return {"list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def categoryContent(self, tid, pg):
        return {"page": pg, "pagecount": 1,
                "list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def detailContent(self, vod_id):
        return {"list": [{"vod_id": vod_id, "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_play_from": "线路1",
                          "vod_play_url": "第1集$" + vod_id}]}

    def searchContent(self, key):
        return {"list": [{"vod_id": "v1", "vod_name": "片一",
                          "vod_pic": "http://x/1.jpg", "vod_remarks": ""}]}

    def playerContent(self, flag, id):
        return {"parse": 0, "url": "http://x/v1.m3u8",
                "header": {"User-Agent": "test"}}
