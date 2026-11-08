package core

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSweep3(t *testing.T) {
	base := "/home/hatch/workspace/huoyi_new/tree_104/assets/novel_json_sources"
	var files []string
	top, _ := filepath.Glob(filepath.Join(base, "*.json"))
	files = append(files, top...)
	sub, _ := filepath.Glob(filepath.Join(base, "yckceo", "*.json"))
	files = append(files, sub...)
	for _, path := range files {
		id := strings.TrimSuffix(filepath.Base(path), ".json")
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Printf("RESULT\t%s\tREAD_FAIL\t0\t%v\n", id, err)
			continue
		}
		src, err := legadoParseSource(data)
		if err != nil {
			fmt.Printf("RESULT\t%s\tPARSE_FAIL\t0\t%v\n", id, err)
			continue
		}
		if strings.Contains(src.ExploreURL, "@js:") {
			fmt.Printf("RESULT\t%s\tJS\t0\t\n", id)
			continue
		}
		if strings.TrimSpace(src.ExploreURL) == "" {
			fmt.Printf("RESULT\t%s\tNOEXPLORE\t0\t\n", id)
			continue
		}
		cats, _ := legadoExploreCategories(src).([]map[string]string)
		if len(cats) == 0 {
			fmt.Printf("RESULT\t%s\tNOCATS\t0\t\n", id)
			continue
		}
		books, err := legadoExplore(src, cats[0]["url"], 1)
		if err != nil {
			fmt.Printf("RESULT\t%s\tERR\t0\t%v\n", id, err)
			continue
		}
		blist, _ := books.([]map[string]string)
		if len(blist) == 0 {
			fmt.Printf("RESULT\t%s\tZERO\t0\t%s\n", id, cats[0]["title"])
			continue
		}
		fmt.Printf("RESULT\t%s\tOK\t%d\t%s\n", id, len(blist), cats[0]["title"])
	}
}
