package moyi

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI

/**
 * 出口决策点的 JVM 落点：生效时把 JVM 默认 [ProxySelector] 换成出口选择器，
 * 非回环 HTTP/HTTPS 请求走出口地址；清掉时恢复之前保存的默认选择器。
 *
 * 受影响的消费方：Exo 的 HttpURLConnection 数据源（Media3 默认数据源走
 * HttpURLConnection，认 JVM 默认选择器）、ProxyKernelBridge 之外的其它
 * HttpURLConnection 调用、以及 jar 蜘蛛在安装之后新建的、未显式指定代理
 * 的 OkHttpClient（OkHttp 在 Builder 创建时抓取当时的默认选择器）。
 *
 * 明确不受控：安装之前已建好的 OkHttpClient、显式写死代理的客户端、
 * 以及一切不走 JVM 代理机制的原生网络栈。回环目标永远直连（内核控制
 * 接口与本机转发器都靠它），非 HTTP(S) 协议也直连。
 *
 * 注意：选择器只认 HTTP 代理语义。SOCKS5 来源的出口地址在 Dart 侧已先
 * 换成本机 HTTP 转发器地址，到这里的永远是 `http://host:port`。
 */
object EgressProxySelector {
    @Volatile
    private var previous: ProxySelector? = null

    @Volatile
    private var egress: Proxy? = null

    @Synchronized
    fun install(proxyUrl: String) {
        val parsed = try {
            URI(proxyUrl)
        } catch (_: Exception) {
            return
        }
        val host = parsed.host ?: return
        val port = parsed.port
        if (port <= 0 || port > 65535) return
        if (egress == null) {
            previous = ProxySelector.getDefault()
        }
        egress = Proxy(Proxy.Type.HTTP, InetSocketAddress(host, port))
        ProxySelector.setDefault(SelectingProxySelector)
    }

    @Synchronized
    fun clear() {
        if (egress == null) return
        egress = null
        val saved = previous
        previous = null
        if (saved != null) {
            ProxySelector.setDefault(saved)
        }
    }

    private object SelectingProxySelector : ProxySelector() {
        override fun select(uri: URI?): List<Proxy> {
            val proxy = egress
            if (uri == null || proxy == null) return listOf(Proxy.NO_PROXY)
            val host = (uri.host ?: "").lowercase()
            if (host == "localhost" || host == "127.0.0.1" ||
                host == "::1" || host == "[::1]"
            ) {
                return listOf(Proxy.NO_PROXY)
            }
            val scheme = (uri.scheme ?: "").lowercase()
            if (scheme != "http" && scheme != "https") {
                return listOf(Proxy.NO_PROXY)
            }
            return listOf(proxy)
        }

        override fun connectFailed(
            uri: URI?,
            address: SocketAddress?,
            failure: IOException?,
        ) {
        }
    }
}
