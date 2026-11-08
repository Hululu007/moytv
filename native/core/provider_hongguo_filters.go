package core

import "slices"

var hongguoDramaCats = []string{"爱情", "年代", "逆袭", "传奇", "成长", "家庭", "家族", "萌宝", "悬疑", "惊悚", "恐怖", "志怪", "古装", "玄幻", "奇幻", "都市", "青春", "喜剧", "科幻", "灾难", "动作冒险", "战争", "综艺", "剧情"}

var hongguoFilterTopics = []string{"现言", "女性成长", "脑洞", "奇幻", "玄幻", "古言", "战神", "宫斗", "仙侠", "权谋", "种田", "年代爱情", "悬疑", "喜剧", "青春", "志怪", "民国爱情", "灵异", "家国情怀", "法律", "刑侦", "抗战", "武侠", "民国传奇", "求生", "动作", "科幻", "恐怖", "商战"}

var hongguoFilterBackgrounds = []string{"现代", "都市", "古代", "乡村", "年代", "架空", "职场", "民国", "校园", "宫廷", "荒岛"}

var hongguoFilterSettings = []string{"打脸虐渣", "大男主", "大女主", "马甲", "重生", "穿越", "系统", "先婚后爱", "家长里短", "小人物", "破镜重圆", "神豪", "豪门", "强者回归", "异能", "虐恋", "传承觉醒", "医生", "强强联合", "赘婿逆袭", "甜宠", "娱乐圈", "神医", "青梅竹马", "姐弟恋", "玄学", "追妻火葬场", "业界精英", "一见钟情", "福宝", "捞偏门", "反派主角", "萌宠", "双向救赎", "方言", "白月光", "灵魂互换", "病娇", "暴富", "黑道", "丧尸", "特种兵"}

func hongguoShortDramaFilterGroups() []nativeFilterGroup {
	opt := func(values []string) []nativeFilterOption {
		out := []nativeFilterOption{{ID: "", Name: "全部"}}
		for _, v := range values {
			out = append(out, nativeFilterOption{ID: v, Name: v})
		}
		return out
	}
	return []nativeFilterGroup{
		{Key: "cat", Name: "分类", Options: opt(hongguoDramaCats)},
		{Key: "topic", Name: "主题", Options: opt(hongguoFilterTopics)},
		{Key: "background", Name: "背景", Options: opt(hongguoFilterBackgrounds)},
		{Key: "setting", Name: "设定", Options: opt(hongguoFilterSettings)},
	}
}

func hongguoFilterShortDramas(items []Drama, filters map[string]string) []Drama {
	wanted := []string{}
	for _, key := range []string{"cat", "topic", "background", "setting"} {
		if v := filters[key]; v != "" {
			wanted = append(wanted, v)
		}
	}
	if len(wanted) == 0 {
		return items
	}
	out := []Drama{}
	for _, item := range items {
		ok := true
		for _, v := range wanted {
			if !slices.Contains(item.Tags, v) && item.CategoryName != v {
				ok = false
				break
			}
		}
		if ok {
			out = append(out, item)
		}
	}
	return out
}
