import 'package:moyi/content_audio.dart';
import 'package:flutter_test/flutter_test.dart';

const _categoryIndex = '''
<a href="/book/kongbuxuanyi/" data-cid="12"  title="恐怖悬疑">恐怖悬疑</a>
<a href="/book/dushiyanqing/" data-cid="13"  title="都市言情">都市言情</a>
<a href="/book/junshilishi/" data-cid="16"  title="军事历史">军事历史</a>
<a href="/book/junshilishi/" data-cid="16"  title="军事历史">军事历史</a>
''';

const _catalogPage = '''
<ul class="m-book-list">
<li>
<a href="/book/QiongGuiDeShangXiaLiangQianNian/" class="full-link" title="穷鬼的上下两千年"></a>
<div class="cover">
<a href="/book/QiongGuiDeShangXiaLiangQianNian/">
<img src="https://www.tingshuwang.cc/d/file/cover/yt/14503/14503.webp" alt="穷鬼的上下两千年">
<em>穷鬼的上下两千年 第469集 豆饭（完结）</em>
</a>
</div>
<div class="info">
<span class="t"><h5><a href="/book/QiongGuiDeShangXiaLiangQianNian/">穷鬼的上下两千年</a><em class="finished">已完结</em></h5></span>
<span class="f">
<em class="click"><i class="iconfont icon-listen"></i>1万</em>
<em class="author"><i class="iconfont icon-voice"></i><a href="/announcer/%E5%85%A8%E5%8B%87/" title="全勇播讲的有声小说" target="_self">全勇</a></em>
</span>
<p class="intro">《穷鬼的上下两千年》有声小说是非玩家角色所着的权谋治癒系历史小说</p>
</div>
</li>
</ul>
<a href="index_2.html">下一页</a>
''';

const _detailPage = '''
<title>大国相有声小说全集-主播：-作者：余人-听书网</title>
<img src="https://www.tingshuwang.cc/d/file/cover/21687/efa0565a4409ff5fb964243843a846ea.gif" alt="大国相">
<a href="/book/DaGuoXiang/25537.html" target="_self" title="大国相 第1350集_贺寿">第1350集_贺寿</a>
<a href="/book/DaGuoXiang/25536.html" target="_self" title="大国相 第1349集_青山下">第1349集_青山下</a>
<a href="/book/DaGuoXiang/21787.html" target="_self" title="大国相 第001集_寒门书生">第001集_寒门书生</a>
''';

const _chapterPage = '''
videourl:'https://www.tingshuwang.cc/d/file/21687/0001.m4a', videotype:'m4a',
''';

void main() {
  group('听书网解析', () {
    test('分类去重', () {
      final categories = parseTingshuwangCategories(_categoryIndex);
      expect(categories.map((c) => c.id), [
        'kongbuxuanyi',
        'dushiyanqing',
        'junshilishi',
      ]);
      expect(categories.last.name, '军事历史');
    });

    test('分类列表卡片与翻页', () {
      final page = parseTingshuwangCatalog(_catalogPage, 1);
      expect(page.items, hasLength(1));
      final book = page.items.first;
      expect(book.id, 'QiongGuiDeShangXiaLiangQianNian');
      expect(book.title, '穷鬼的上下两千年');
      expect(book.cover, contains('d/file/cover'));
      expect(book.author, '全勇');
      expect(book.remarks, contains('已完结'));
      expect(book.intro, contains('权谋'));
      expect(page.hasMore, isTrue);
      expect(parseTingshuwangCatalog(_catalogPage, 2).hasMore, isFalse);
    });

    test('详情章节倒序回正序', () {
      final detail = parseTingshuwangDetail(_detailPage, 'DaGuoXiang');
      expect(detail.book.title, '大国相');
      expect(detail.book.author, '余人');
      expect(detail.book.cover, contains('d/file/cover'));
      expect(detail.chapters, hasLength(3));
      expect(detail.chapters.first.title, '第001集_寒门书生');
      expect(detail.chapters.first.id, endsWith('/21787.html'));
      expect(detail.chapters.last.title, '第1350集_贺寿');
    });

    test('章节音频地址', () {
      expect(
        parseTingshuwangAudioUrl(_chapterPage),
        'https://www.tingshuwang.cc/d/file/21687/0001.m4a',
      );
      expect(
        () => parseTingshuwangAudioUrl('<html></html>'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
