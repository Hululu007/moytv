package core

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSweepAdult(t *testing.T) {
	files := []string{
		"40fb7103453e_com.json",
		"66story_com.json",
		"bbqqgg_com.json",
		"blshuge_com_4.json",
		"blshuge_com_7.json",
		"diyibanzhu_me_12.json",
		"diyibanzhu_me_8.json",
		"jjmh_top.json",
		"jjmh_top_2.json",
		"jjmh_top_6.json",
		"jsk1_top.json",
		"m_longtengxiaoshuo_org.json",
		"m_nprouwen_org.json",
		"m_nprouwen_org_2.json",
		"m_nprouwen_org_3.json",
		"m_rouwenwu14_com.json",
		"m_rouwenwu14_com_2.json",
		"m_rouwenwu14_com_3.json",
		"m_rouwenwu14_com_4.json",
		"m_rouwenwu14_com_5.json",
		"m_rouwenwu14_com_6.json",
		"m_rouwenwu14_com_7.json",
		"m_yuwangshe_net.json",
		"m_yuwangshe_net_2.json",
		"m_yuwangshe_net_3.json",
		"m_yuwangshe_net_4.json",
		"m_yuwangshe_net_5.json",
		"m_yuwangshe_net_6.json",
		"m_yuwangshe_net_7.json",
		"m_yuwangshe_one.json",
		"mqzjw_com_2.json",
		"powenxue15_com.json",
		"rouwennp_org.json",
		"rouwennp_org_2.json",
		"rouwennp_org_3.json",
		"rouwennp_org_4.json",
		"rouwennp_org_5.json",
		"rouwennp_org_6.json",
		"rouwennp_org_7.json",
		"rouwennp_org_8.json",
		"win10city_com.json",
	}
	base := "/home/hatch/workspace/reading_convert/site_sources"
	for _, fn := range files {
		path := filepath.Join(base, fn)
		id := strings.TrimSuffix(fn, ".json")
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Printf("ADULT\t%s\tREAD_FAIL\t0\t%v\n", id, err)
			continue
		}
		src, err := legadoParseSource(data)
		if err != nil {
			fmt.Printf("ADULT\t%s\tPARSE_FAIL\t0\t%v\n", id, err)
			continue
		}
		if strings.Contains(src.ExploreURL, "@js:") {
			fmt.Printf("ADULT\t%s\tJS\t0\t%d\n", id, src.Type)
			continue
		}
		if strings.TrimSpace(src.ExploreURL) == "" {
			fmt.Printf("ADULT\t%s\tNOEXPLORE\t0\t%d\n", id, src.Type)
			continue
		}
		cats, _ := legadoExploreCategories(src).([]map[string]string)
		if len(cats) == 0 {
			fmt.Printf("ADULT\t%s\tNOCATS\t0\t%d\n", id, src.Type)
			continue
		}
		books, err := legadoExplore(src, cats[0]["url"], 1)
		if err != nil {
			fmt.Printf("ADULT\t%s\tERR\t0\t%d\t%v\n", id, src.Type, err)
			continue
		}
		blist, _ := books.([]map[string]string)
		if len(blist) == 0 {
			fmt.Printf("ADULT\t%s\tZERO\t0\t%d\t%s\n", id, src.Type, cats[0]["title"])
			continue
		}
		fmt.Printf("ADULT\t%s\tOK\t%d\t%d\t%s\n", id, len(blist), src.Type, cats[0]["title"])
	}
}
