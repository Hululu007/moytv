package core

var youtubeFilterTags = map[string][]string{
	"preset:动漫":   {"一口气看完", "国漫", "日本", "修仙", "穿越", "热血", "搞笑", "恋爱", "科幻", "儿童", "小猪佩奇", "CoComelon", "国漫社"},
	"preset:短剧":   {"总裁", "穿越", "重生", "古装", "现代", "甜宠", "复仇", "抖音", "快手", "大陆", "香港", "台湾"},
	"preset:电视剧":  {"古装", "现代", "谍战", "悬疑", "爱情", "家庭", "历史", "都市"},
	"preset:电影":   {"大陆", "国产", "动作", "喜剧", "爱情", "科幻", "悬疑", "战争", "动画", "剧情"},
	"preset:战争片":  {"大陆", "国产", "抗日", "抗美援朝", "二战", "现代战争", "谍战", "历史", "经典"},
	"preset:沙雕动漫": {"穿越", "修仙", "重生", "系统", "搞笑", "玄幻", "都市", "古代"},
	"preset:新闻":   {"国内", "国际", "社会", "财经", "科技", "娱乐", "军事", "CCTV", "凤凰卫视", "TVB", "东森", "三立"},
	"preset:纪录片":  {"自然", "历史", "科学", "人文", "动物", "宇宙", "美食", "旅行"},
	"preset:综艺":   {"真人秀", "脱口秀", "选秀", "音乐", "搞笑", "访谈", "亲子"},
	"preset:体育":   {"足球", "篮球", "网球", "赛车", "健身", "拳击", "奥运", "电竞"},
	"preset:科技":   {"数码", "AI", "手机", "电脑", "科学", "发明", "评测", "教程"},
	"preset:时尚":   {"穿搭", "美妆", "潮流", "模特", "设计", "奢侈品", "街拍"},
	"preset:科普":   {"宇宙", "物理", "生物", "化学", "天文", "地理", "医学", "心理"},
	"preset:新闻直播": {"CCTV", "CNN", "BBC", "凤凰卫视", "TVB", "东森", "三立", "Live"},
	"preset:4K":   {"4K", "HDR", "风景", "城市", "自然", "延时", "航拍", "8K"},
	"preset:学习":   {"英语", "数学", "编程", "历史", "科学", "考试", "职场"},
	"shorts":      {"搞笑", "音乐", "舞蹈", "美食", "宠物", "游戏", "运动", "旅行"},
}

var youtubeFilterSeries = []string{"遮天", "凡人修仙传", "斗破苍穹", "斗罗大陆", "完美世界", "吞噬星空", "一人之下", "秦时明月", "画江湖之不良人", "灵笼", "伍六七", "诛仙", "剑来", "海贼王", "火影忍者", "鬼灭之刃"}

func youtubeFilterOptions(values []string) []nativeFilterOption {
	out := []nativeFilterOption{{ID: "", Name: "全部"}}
	for _, v := range values {
		out = append(out, nativeFilterOption{ID: v, Name: v})
	}
	return out
}

func youtubeFilterGroups(category string) []nativeFilterGroup {
	groups := []nativeFilterGroup{
		{Key: "地区", Name: "地区", Options: []nativeFilterOption{{ID: "", Name: "全部"}, {ID: "US", Name: "美国"}, {ID: "HK", Name: "香港"}, {ID: "TW", Name: "台湾"}, {ID: "JP", Name: "日本"}, {ID: "KR", Name: "韩国"}, {ID: "GB", Name: "英国"}}},
	}
	if category == "preset:动漫" {
		groups = append(groups, nativeFilterGroup{Key: "二级分类", Name: "二级分类", Options: youtubeFilterOptions(youtubeFilterSeries)})
	}
	if tags, ok := youtubeFilterTags[category]; ok {
		groups = append(groups,
			nativeFilterGroup{Key: "时间", Name: "时间", Options: []nativeFilterOption{{ID: "", Name: "全部"}, {ID: "today", Name: "今天"}, {ID: "week", Name: "本周"}, {ID: "month", Name: "本月"}, {ID: "year", Name: "今年"}}},
			nativeFilterGroup{Key: "年份", Name: "年份", Options: youtubeFilterOptions([]string{"2026", "2025", "2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2016", "2015"})},
			nativeFilterGroup{Key: "标签", Name: "标签", Options: youtubeFilterOptions(tags)},
		)
	}
	return groups
}
