bool isAdultSourceName(String name) => name.startsWith('🔞');

List<T> filterSourcesByAdult<T>(
  List<T> sources,
  String Function(T) nameOf,
  bool? adultOnly,
) {
  if (adultOnly == null) return sources;
  return [
    for (final source in sources)
      if (isAdultSourceName(nameOf(source)) == adultOnly) source,
  ];
}
