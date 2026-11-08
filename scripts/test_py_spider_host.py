import base64
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST_PATH = ROOT / "android" / "app" / "src" / "main" / "python" / "py_spider_host.py"

FIXTURE = '''
import json
import re
import urllib.parse


class Spider:
    def getName(self):
        return "Fixture站"

    def getDependence(self):
        return []

    def init(self, extend=""):
        self.ext = extend
        return None

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        return {
            "class": [{"type_id": "movie", "type_name": "电影"}],
            "list": [{"vod_id": "1", "vod_name": "首页片", "vod_pic": "https://img.test/1.jpg", "vod_remarks": "HD"}],
        }

    def homeVideoContent(self):
        return {"list": [{"vod_id": "2", "vod_name": "推荐片", "vod_pic": "", "vod_remarks": ""}]}

    def categoryContent(self, tid=None, pg=1, filter=None, extend=None):
        if str(tid).startswith("actress:"):
            return {"list": [{"vod_id": "9", "vod_name": "女优作品", "vod_pic": "", "vod_remarks": "1:02:03"}], "page": pg, "pagecount": 1}
        return {"list": [
            {"vod_id": "actress:abc", "vod_name": "某女优", "vod_pic": "https://img.test/a.jpg", "vod_remarks": "12 视频", "vod_tag": "folder"},
            {"vod_id": "3", "vod_name": "分类片", "vod_pic": "", "vod_remarks": ""},
        ], "page": pg, "pagecount": 2}

    def detailContent(self, ids=None):
        vid = str(ids[0]) if ids else ""
        return {"list": [{
            "vod_id": vid,
            "vod_name": "详情片",
            "vod_pic": "https://img.test/d.jpg",
            "vod_content": "简介文本",
            "vod_play_from": "线路A$$$线路B",
            "vod_play_url": "第1集$https://play.test/1.m3u8#第2集$https://play.test/2.m3u8$$$正片$https://play.test/main.mp4",
        }]}

    def searchContent(self, key=None, quick=False, pg="1"):
        return {"list": [{"vod_id": "5", "vod_name": "搜到:" + str(key), "vod_pic": "", "vod_remarks": ""}], "page": int(pg)}

    def playerContent(self, flag=None, id=None, vipFlags=None):
        return {"parse": 0, "jx": 0, "playUrl": "", "url": str(id or ""), "header": {"User-Agent": "FixtureUA", "Referer": "https://site.test/"}}

    def localProxy(self, param=None):
        return [404, "text/plain", b"bad url", {}]

    def isVideoFormat(self, url=None):
        return ".m3u8" in str(url or "")

    def manualVideoCheck(self):
        return False

    def action(self, action=None):
        return {}
'''


LOOSE_FIXTURE = '''
import definitely_missing_xyz
import requests


class Spider:
    def playerContent(self, flag=None, id=None, vipFlags=None):
        return {"parse": 0, "url": "https://play.test/loose.m3u8", "header": {}}
'''


def load_host():
    spec = importlib.util.spec_from_file_location("py_spider_host", HOST_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["py_spider_host"] = module
    spec.loader.exec_module(module)
    return module


class PySpiderHostTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = load_host()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.spider_path = str(Path(cls.tmp.name) / "fixture.py")
        Path(cls.spider_path).write_text(FIXTURE, encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def call(self, request):
        raw = self.host.handle(self.spider_path, json.dumps(request))
        return json.loads(raw)

    def test_validate_ok(self):
        result = self.host.validate_source(FIXTURE)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["missing"], [])
        self.assertTrue(result["hasSpider"])

    def test_validate_missing_methods(self):
        broken = FIXTURE.replace("def playerContent", "def gonePlayerContent")
        broken = broken.replace("def localProxy", "def goneLocalProxy")
        result = self.host.validate_source(broken)
        self.assertFalse(result["ok"])
        self.assertIn("playerContent", result["missing"])
        self.assertNotIn("localProxy", result["missing"])
        self.assertIn("localProxy", result["filled"])
        self.assertIn("playerContent", result["error"])

    def test_validate_defaulted_only_missing_ok(self):
        relaxed = FIXTURE
        for name in (
            "getDependence",
            "destroy",
            "localProxy",
            "isVideoFormat",
            "manualVideoCheck",
            "action",
        ):
            relaxed = relaxed.replace("def %s" % name, "def gone_%s" % name)
        result = self.host.validate_source(relaxed)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["missing"], [])
        self.assertEqual(sorted(result["filled"]), sorted([
            "getDependence", "destroy", "localProxy",
            "isVideoFormat", "manualVideoCheck", "action",
        ]))

    def test_defaulted_spider_runs_with_filled_defaults(self):
        relaxed = FIXTURE
        for name in ("destroy", "action", "getDependence"):
            relaxed = relaxed.replace("def %s" % name, "def gone_%s" % name)
        path = str(Path(self.tmp.name) / "relaxed.py")
        Path(path).write_text(relaxed, encoding="utf-8")
        raw = self.host.handle(path, json.dumps({"action": "ping"}))
        result = json.loads(raw)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["name"], "Fixture站")
        self.assertEqual(len(result["data"]["methods"]), 14)
        disposed = json.loads(self.host.dispose(path))
        self.assertTrue(disposed["ok"])

    def test_validate_play_only_ok(self):
        result = self.host.validate_source(LOOSE_FIXTURE)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["mode"], "playOnly")
        self.assertEqual(result["missing"], [])
        self.assertIn("homeContent", result["filled"])
        self.assertIn("detailContent", result["filled"])
        self.assertIn("destroy", result["filled"])
        self.assertNotIn("playerContent", result["filled"])

    def test_validate_play_only_requires_player_content(self):
        broken = FIXTURE.replace("def playerContent", "def gonePlayerContent")
        broken = broken.replace("def homeContent", "def goneHomeContent")
        result = self.host.validate_source(broken)
        self.assertFalse(result["ok"])
        self.assertIn("playerContent", result["missing"])

    def test_play_only_full_chain(self):
        path = str(Path(self.tmp.name) / "loose.py")
        Path(path).write_text(LOOSE_FIXTURE, encoding="utf-8")

        def run(request):
            return json.loads(self.host.handle(path, json.dumps(request)))

        ping = run({"action": "ping"})
        self.assertTrue(ping["ok"], ping)
        self.assertEqual(len(ping["data"]["methods"]), 14)
        self.assertIn("definitely_missing_xyz", ping["data"]["stubbedImports"])
        self.assertIn("homeContent", ping["data"]["filled"])
        catalog = run({"action": "catalog", "page": 1})
        self.assertTrue(catalog["ok"], catalog)
        self.assertEqual(catalog["data"]["list"][0]["vod_id"], "play")
        detail = run({"action": "detail", "vodId": "play"})
        self.assertTrue(detail["ok"], detail)
        self.assertEqual(detail["data"]["list"][0]["vod_play_url"], "正片$play")
        resolve = run(
            {"action": "resolve", "flag": "默认", "playId": "play"}
        )
        self.assertTrue(resolve["ok"], resolve)
        self.assertEqual(resolve["data"]["url"], "https://play.test/loose.m3u8")
        self.assertIsInstance(resolve["data"]["header"], dict)
        search = run({"action": "catalog", "query": "x", "page": 1})
        self.assertTrue(search["ok"], search)
        self.assertEqual(search["data"]["list"], [])

    def test_requests_shim_get_json(self):
        import http.server
        import threading

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'{"hello": "world"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            shim = self.host._make_requests_module()
            response = shim.get(
                "http://127.0.0.1:%d/x" % server.server_address[1]
            )
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), {"hello": "world"})
            self.assertEqual(response.text, '{"hello": "world"}')
        finally:
            server.shutdown()
            server.server_close()

    def test_validate_no_spider(self):
        result = self.host.validate_source("class Other:\n    pass\n")
        self.assertFalse(result["ok"])
        self.assertFalse(result["hasSpider"])

    def test_validate_syntax_error(self):
        result = self.host.validate_source("class Spider(:\n")
        self.assertFalse(result["ok"])
        self.assertIn("语法错误", result["error"])

    def test_ping(self):
        result = self.call({"action": "ping"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["name"], "Fixture站")
        self.assertEqual(len(result["data"]["methods"]), 14)

    def test_categories(self):
        result = self.call({"action": "categories"})
        self.assertTrue(result["ok"], result)
        classes = result["data"]["class"]
        self.assertEqual(classes[0]["type_id"], "movie")

    def test_catalog_category_folder_item(self):
        result = self.call({"action": "catalog", "category": "movie", "page": 1})
        self.assertTrue(result["ok"], result)
        items = result["data"]["list"]
        self.assertEqual(items[0]["vod_tag"], "folder")
        self.assertEqual(result["data"]["pagecount"], 2)

    def test_catalog_drill_category(self):
        result = self.call({"action": "catalog", "category": "actress:abc", "page": 1})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["list"][0]["vod_name"], "女优作品")

    def test_catalog_search_query(self):
        result = self.call({"action": "catalog", "query": "测试", "page": 1})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["list"][0]["vod_name"], "搜到:测试")

    def test_detail_raw(self):
        result = self.call({"action": "detail", "vodId": "42"})
        self.assertTrue(result["ok"], result)
        item = result["data"]["list"][0]
        self.assertEqual(item["vod_id"], "42")
        self.assertIn("$$$", item["vod_play_url"])

    def test_resolve_header_is_dict(self):
        result = self.call(
            {"action": "resolve", "flag": "线路A", "playId": "https://play.test/1.m3u8"}
        )
        self.assertTrue(result["ok"], result)
        self.assertIsInstance(result["data"]["header"], dict)
        self.assertEqual(result["data"]["header"]["User-Agent"], "FixtureUA")
        self.assertEqual(result["data"]["url"], "https://play.test/1.m3u8")

    def test_resolve_parse_flag_passthrough(self):
        variant = FIXTURE.replace('"parse": 0', '"parse": 1', 1)
        variant_path = str(Path(self.tmp.name) / "fixture_parse.py")
        Path(variant_path).write_text(variant, encoding="utf-8")
        raw = self.host.handle(
            variant_path,
            json.dumps(
                {"action": "resolve", "flag": "线路A", "playId": "https://page.test/play"}
            ),
        )
        result = json.loads(raw)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["parse"], 1)
        self.assertEqual(result["data"]["url"], "https://page.test/play")

    def test_proxy_bytes_base64(self):
        result = self.call({"action": "proxy", "param": {"url": ""}})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["status"], 404)
        self.assertEqual(base64.b64decode(result["data"]["bodyBase64"]), b"bad url")

    def test_unknown_action_errors_loudly(self):
        result = self.call({"action": "nope"})
        self.assertFalse(result["ok"])
        self.assertIn("不支持的动作", result["error"])


STRICT_FIXTURE = '''
import base64


class Spider:
    def getName(self):
        return "Strict站"

    def getDependence(self):
        return ["dep1"]

    def init(self, extend=""):
        self.ext = extend

    def destroy(self):
        return None

    def homeContent(self, filter=None):
        return {
            "class": [{"type_id": "movie", "type_name": "电影"}],
            "list": [],
            "filters": {"movie": [{"key": "area", "name": "地区", "value": [{"n": "全部", "v": ""}, {"n": "大陆", "v": "大陆"}]}]},
        }

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        return {"list": [], "page": pg, "page_type": type(pg).__name__, "filter": filter, "extend": extend, "ext_seen": getattr(self, "ext", None)}

    def detailContent(self, ids):
        return {"list": []}

    def searchContent(self, key, quick, pg):
        return {"list": [], "page_type": type(pg).__name__}

    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": id, "header": {}}

    def localProxy(self, param):
        mode = param.get("mode") if isinstance(param, dict) else None
        if mode == "b64":
            return [200, "image/png", base64.b64encode(b"\\x89PNG").decode("ascii"), {}, 1]
        if mode == "badbody":
            return [200, "text/plain", 12345, {}]
        if mode == "badheaders":
            return [200, "text/plain", "ok", "notadict"]
        return [200, "text/plain", "ok", {}]

    def isVideoFormat(self, url):
        return str(url).endswith(".m3u8")

    def manualVideoCheck(self):
        return True

    def action(self, action):
        return {"got": action}
'''


BAD_ARITY_FIXTURE = '''
class Spider:
    def getName(self):
        return "BadArity站"

    def init(self, extend=""):
        return None

    def homeContent(self, filter=None):
        return {"class": [], "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid, pg, filter, extend):
        if extend:
            raise TypeError("categoryContent() takes 3 positional arguments but 4 were given")
        return {"list": [], "page": pg}

    def detailContent(self, ids):
        return {"list": []}

    def searchContent(self, key, quick, pg):
        return {"list": []}

    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": id, "header": {}}
'''


class PySpiderHostStrictTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = load_host()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.spider_path = str(Path(cls.tmp.name) / "strict.py")
        Path(cls.spider_path).write_text(STRICT_FIXTURE, encoding="utf-8")
        cls.bad_path = str(Path(cls.tmp.name) / "badarity.py")
        Path(cls.bad_path).write_text(BAD_ARITY_FIXTURE, encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def call_on(self, path, request):
        return json.loads(self.host.handle(path, json.dumps(request)))

    def test_new_actions_direct_call(self):
        result = self.call_on(self.spider_path, {"action": "dependence"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"], ["dep1"])
        result = self.call_on(self.spider_path, {"action": "format", "url": "https://x.test/a.m3u8"})
        self.assertTrue(result["ok"], result)
        self.assertIs(result["data"], True)
        result = self.call_on(self.spider_path, {"action": "format", "url": "https://x.test/page"})
        self.assertTrue(result["ok"], result)
        self.assertIs(result["data"], False)
        result = self.call_on(self.spider_path, {"action": "check"})
        self.assertTrue(result["ok"], result)
        self.assertIs(result["data"], True)
        result = self.call_on(self.spider_path, {"action": "action", "name": "fav"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"], {"got": "fav"})

    def test_home_action_returns_filters(self):
        result = self.call_on(self.spider_path, {"action": "home"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["filters"]["movie"][0]["key"], "area")

    def test_pg_normalized_to_int(self):
        result = self.call_on(self.spider_path, {"action": "catalog", "category": "movie", "page": "2"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["page_type"], "int")
        self.assertEqual(result["data"]["page"], 2)
        result = self.call_on(self.spider_path, {"action": "catalog", "query": "x", "page": 3})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["page_type"], "int")

    def test_filter_extend_passthrough(self):
        result = self.call_on(self.spider_path, {
            "action": "catalog", "category": "movie", "page": 1,
            "filter": True, "extend": {"area": "大陆"},
        })
        self.assertTrue(result["ok"], result)
        self.assertIs(result["data"]["filter"], True)
        self.assertEqual(result["data"]["extend"], {"area": "大陆"})

    def test_extend_fingerprint_reinit(self):
        first = self.call_on(self.spider_path, {"action": "catalog", "category": "movie", "page": 1, "extend": "A"})
        self.assertEqual(first["data"]["ext_seen"], "A")
        second = self.call_on(self.spider_path, {"action": "catalog", "category": "movie", "page": 1, "extend": "B"})
        self.assertEqual(second["data"]["ext_seen"], "B")
        third = self.call_on(self.spider_path, {"action": "catalog", "category": "movie", "page": 1})
        self.assertEqual(third["data"]["ext_seen"], "")

    def test_proxy_five_item_base64(self):
        result = self.call_on(self.spider_path, {"action": "proxy", "param": {"mode": "b64"}})
        self.assertTrue(result["ok"], result)
        self.assertEqual(base64.b64decode(result["data"]["bodyBase64"]), b"\x89PNG")

    def test_proxy_body_type_errors_loudly(self):
        result = self.call_on(self.spider_path, {"action": "proxy", "param": {"mode": "badbody"}})
        self.assertFalse(result["ok"])
        self.assertIn("body", result["error"])

    def test_proxy_headers_non_dict_tolerated(self):
        result = self.call_on(self.spider_path, {"action": "proxy", "param": {"mode": "badheaders"}})
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["data"]["headers"], {})

    def test_internal_arity_worded_error_propagates(self):
        result = self.call_on(self.bad_path, {
            "action": "catalog", "category": "movie", "page": 1, "extend": {"area": "大陆"},
        })
        self.assertFalse(result["ok"])
        self.assertIn("takes 3 positional arguments", result["error"])


class PySpiderHostErrorLabelTest(unittest.TestCase):
    def test_resolve_failure_names_action_and_method(self):
        host = load_host()
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "boom.py")
            Path(path).write_text(
                "class Spider:\n"
                "    def getName(self):\n"
                "        return 'Boom'\n"
                "    def init(self, extend=''):\n"
                "        return None\n"
                "    def playerContent(self, flag=None, id=None, vipFlags=None):\n"
                "        raise RuntimeError('upstream down')\n",
                encoding="utf-8",
            )
            result = json.loads(
                host.handle(path, json.dumps({"action": "resolve", "flag": "f", "playId": "1"}))
            )
        self.assertFalse(result["ok"])
        self.assertIn("resolve/playerContent", result["error"])
        self.assertIn("upstream down", result["error"])


CACHE_FIXTURE = '''
from base.spider import Spider as BaseSpider


class Spider(BaseSpider):
    def getName(self):
        return "CacheSpider"

    def init(self, extend=""):
        return None

    def homeContent(self, filter=None):
        return {"class": [], "list": []}

    def homeVideoContent(self):
        return {"list": []}

    def categoryContent(self, tid=None, pg=1, filter=None, extend=None):
        return {"list": [], "page": pg, "pagecount": 1}

    def detailContent(self, ids=None):
        return {"list": []}

    def searchContent(self, key=None, quick=False, pg="1"):
        return {"list": [], "page": 1}

    def playerContent(self, flag=None, id=None, vipFlags=None):
        return {"parse": 0, "url": id, "header": {}}
'''


class PySpiderHostCacheTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = load_host()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.path_a = str(Path(cls.tmp.name) / "cache_a.py")
        cls.path_b = str(Path(cls.tmp.name) / "cache_b.py")
        Path(cls.path_a).write_text(CACHE_FIXTURE, encoding="utf-8")
        Path(cls.path_b).write_text(CACHE_FIXTURE, encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_get_miss_returns_default(self):
        spider = self.host._load_spider(self.path_a)
        self.assertIsNone(spider.getCache("never_set_key"))
        self.assertEqual(spider.getCache("never_set_key", "dflt"), "dflt")

    def test_set_get_put_del_roundtrip(self):
        spider = self.host._load_spider(self.path_a)
        self.assertTrue(spider.setCache("rt_host", "h1"))
        self.assertEqual(spider.getCache("rt_host"), "h1")
        self.assertTrue(spider.putCache("rt_host", "h2"))
        self.assertEqual(spider.getCache("rt_host"), "h2")
        self.assertTrue(spider.setCache(
            "rt_obj", {"url": "https://x.test/a.m3u8", "expires": 9999999999}
        ))
        self.assertEqual(
            spider.getCache("rt_obj")["url"], "https://x.test/a.m3u8"
        )
        self.assertTrue(spider.delCache("rt_host"))
        self.assertIsNone(spider.getCache("rt_host"))
        self.assertFalse(spider.delCache("rt_host"))

    def test_expired_ttl_returns_default(self):
        spider = self.host._load_spider(self.path_a)
        spider.setCache("rt_short", "v", ttl=-1)
        self.assertIsNone(spider.getCache("rt_short"))
        spider.setCache("rt_long", "v", ttl=3600)
        self.assertEqual(spider.getCache("rt_long"), "v")

    def test_persists_across_reload_and_isolated_per_spider(self):
        spider_a = self.host._load_spider(self.path_a)
        spider_a.setCache("rt_shared", "from-a")
        spider_b = self.host._load_spider(self.path_b)
        self.assertIsNone(spider_b.getCache("rt_shared"))
        self.host.dispose(self.path_a)
        reloaded = self.host._load_spider(self.path_a)
        self.assertEqual(reloaded.getCache("rt_shared"), "from-a")


if __name__ == "__main__":
    unittest.main()
