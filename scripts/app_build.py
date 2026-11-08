import base64
from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False

    @property
    def name(self):
        return '魔蚁box' if self.all_sources else '短剧视界'

    @property
    def slug(self):
        return 'moyi' if self.all_sources else 'duanjushijie'

    @property
    def arguments(self):
        return ['--all-sources'] if self.all_sources else []

    @property
    def flutter_arguments(self):
        return ['--dart-define=ALL_SOURCES=' + str(self.all_sources).lower()]

    @property
    def linker_flags(self):
        return '-s -w -X moyi/native/core.buildAllSources=' + str(self.all_sources).lower()

    @classmethod
    def from_dart_defines(cls, encoded):
        values = {}
        for item in encoded.split(','):
            if not item:
                continue
            key, separator, value = base64.b64decode(item, validate=True).decode('utf-8').partition('=')
            if separator:
                values[key] = value
        return cls(values.get('ALL_SOURCES') == 'true')


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的魔蚁box；默认构建仅红果的短剧视界')


def pubspec_build_number(root):
    """读取 pubspec.yaml 的 version: X.Y.Z+N 并返回构建号 N；缺失时返回 0。"""
    import re
    from pathlib import Path

    pubspec = Path(root) / 'pubspec.yaml'
    try:
        text = pubspec.read_text(encoding='utf-8')
    except OSError:
        return 0
    match = re.search(r'^version:\s*[^+\s]+\+(\d+)\s*$', text, re.MULTILINE)
    return int(match.group(1)) if match else 0
