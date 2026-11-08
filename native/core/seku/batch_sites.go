package seku

// registerBatchSites registers the batch-ported sites (py sources first,
// then jar MacCMS candidates). Filled in per engine in sites_*.go files.
func registerBatchSites() {
	registerPySites()
	registerJarSites()
}
