var lazy = $('').lazyRule(() => {
    var res = fetch(input);
    var high = pd(res, 'body&&video&&[size=1080]&&src');
    var low = pd(res, 'body&&video&&source&&src');
    if (high) {
        return high;
    } else {
        return low;
    }
});