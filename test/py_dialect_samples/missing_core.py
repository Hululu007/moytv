class Spider:
    def getName(self):
        return "missing_core"

    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        return {"class": [], "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        return {"list": []}

    def detailContent(self, ids):
        return {"list": []}

    def searchContent(self, key, quick, pg):
        return {"list": []}
