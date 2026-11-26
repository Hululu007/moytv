const String kReleaseRepoSlug = 'hoyittvggfh45/moytv';

const String kCoreReleaseTagPrefix = 'core-';

bool get updateSourceConfigured => kReleaseRepoSlug.contains('/');

String? get releasesApiUrl => updateSourceConfigured
    ? 'https://api.github.com/repos/$kReleaseRepoSlug/releases?per_page=30'
    : null;

String? get releasesPageUrl => updateSourceConfigured
    ? 'https://github.com/$kReleaseRepoSlug/releases'
    : null;
