function substr(str, maxLength) {
  let len = 0;
  for (let i = 0; i < str.length; i++) {
    if (str.charCodeAt(i) > 255) {
      len += 2;
    } else {
      len++;
    }
    if (len > maxLength) {
      return str.slice(0, i) + '...';
    }
  }
  return str;
}

function setDesc(arr, desc, num) {
  //log(desc)
  if (desc == undefined) {
    return;
  }
  desc = desc.constructor == Array ? desc.join('<br>') : desc;
  if (desc.replace(/(<br>|\s+|<\/?p>|&nbsp;)/g, '').length == 0) {
    return;
  }

  const mark = 'desc';
  num = typeof (num) == 'undefined' ? 100 : num
  desc = desc.startsWith('　　') ? desc : '　　' + desc;
  desc = desc.replace(/'/g, "&#39;");
  desc = desc.replace(/\r\n/g, "<br>");
  desc = desc.replace(/\r/g, "<br>");
  desc = desc.replace(/\n/g, "<br>");
  let sdesc = substr(desc, num);

  var colors = {
    show: "#666666",
    hide: "grey"
  }

  var lazy = $(`#noLoading#`).lazyRule((dc, sdc, m, cs) => {
    var show = storage0.getItem(m, '0');
    var title = findItem('desc').title;
    var re = /(<\/small><br>.*?>).+/g;
    var exp = '展开:';
    var ret = '收起:';
    if (show == '1') {
      updateItem('desc', {
        title: title
          .replace(ret, exp)
          .replace(re, '$1' + sdc + '</small>')
          .replace(/(<\/small><br>\<font color=").*?(">)/, '$1' + cs.hide + '$2')

      })
      storage0.setItem(m, '0');
    } else {
      updateItem('desc', {
        title: title
          .replace(exp, ret)
          .replace(re, '$1' + dc + '</small>')
          .replace(/(<\/small><br>\<font color=").*?(">)/, '$1' + cs.show + '$2')
      })
      storage0.setItem(m, '1');
    }
    return `hiker://empty`
  }, desc, sdesc, mark, colors)
  var sc = storage0.getItem(mark, '0') == '0' ? '展开:' : '收起:';
  var dc = storage0.getItem(mark, '0') == '0' ? sdesc : desc;
  var cs = storage0.getItem(mark, '0') == '0' ? colors.hide : colors.show;
  arr.push({
    title: '' + '<b><font color="#098AC1">∷剧情简介	</font></b>' + "<small><a style='text-decoration: none;' href='" + lazy + "'>" + sc + '</a></small><br><font color="' + cs + '">' + `${dc}` + '</small>',
    col_type: 'rich_text',
    extra: {
      id: 'desc',
      lineSpacing: 6,
      textSize: 15,
      lineVisible: true,
    }
  })
}

//setDesc(d, desc);