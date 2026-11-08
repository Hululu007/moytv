package core

type providerDescriptor struct {
	ID              string
	SupportsFilters bool
	FilterNote      string
}

var nativeProviderRegistry = []providerDescriptor{
	{ID: sourceHGTV, SupportsFilters: true},
	{ID: sourceHGTVMirror, FilterNote: "镜站分类页无筛选组"},
	{ID: sourceHongguo, SupportsFilters: true},
	{ID: "youtube", SupportsFilters: true},
	{ID: sourceHuangdou, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceHuangguoAI, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceHuangju, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceYeguo, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceDSD, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceGuipian, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceHanxiaoquan, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceIkanbot, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceA123, FilterNote: "目录接口未返回筛选组"},
	{ID: sourceHuangguoVideo, FilterNote: "目录为固定列表接口，未返回筛选组"},
	{ID: sourceCloudFront, FilterNote: "旧版目录接口，未返回筛选组"},
}

func providerSupportsFilters(source string) bool {
	for _, descriptor := range nativeProviderRegistry {
		if descriptor.ID == source {
			return descriptor.SupportsFilters
		}
	}
	return false
}

func shouldUseRetryCache(retryErr error, cachedItems int) bool {
	return retryErr != nil && cachedItems > 0
}
