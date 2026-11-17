var lazy = $('').lazyRule(() => {
    try {
        var res = fetch(input);
        var high = pd(res, 'body&&video&&[size=1080]&&src');
        var low = pd(res, 'body&&video&&source&&src');
        if (high) return high;
        if (low) return low;
        return 'toast://解析失败';
    } catch (e) {
        return 'toast://解析失败';
    }
});