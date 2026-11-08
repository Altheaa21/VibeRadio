import Foundation
import Combine
#if canImport(Darwin)
import Darwin
#endif

/// 局域网 UPnP/DLNA 音箱（MediaRenderer）：SSDP 发现 → 读取设备描述 → 用 AVTransport 投放当前歌曲。
/// iOS 上发多播需要 Apple 单独批准的 multicast 权限，所以发现只在 Mac 上启用。
struct UPnPRenderer: Identifiable, Equatable {
    let name: String
    let location: URL
    let controlURL: URL
    var id: String { controlURL.absoluteString }
}

enum UPnPProtocol {
    static let searchTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"
    static var searchMessage: String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\n\r\n"
    }
    /// 从 SSDP 回应里取 LOCATION（只接受局域网 http 地址）。
    static func location(fromSSDP response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            guard let url = URL(string: parts[1].trimmingCharacters(in: .whitespaces)), url.scheme == "http", let host = url.host, isPrivate(host) else { return nil }
            return url
        }
        return nil
    }
    static func isPrivate(_ host: String) -> Bool {
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }
    /// 解析设备描述 XML：取设备名和 AVTransport 的 controlURL。
    static func renderer(fromDescription xml: Data, location: URL) -> UPnPRenderer? {
        let parser = DescriptionParser()
        let xmlParser = XMLParser(data: xml); xmlParser.delegate = parser
        guard xmlParser.parse(), let control = parser.avTransportControl else { return nil }
        let base = parser.urlBase.flatMap(URL.init(string:)) ?? location
        guard let url = URL(string: control, relativeTo: base)?.absoluteURL, url.host == location.host else { return nil }
        return UPnPRenderer(name: parser.friendlyName.isEmpty ? (location.host ?? "音箱") : String(parser.friendlyName.prefix(60)), location: location, controlURL: url)
    }
    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var friendlyName = "", urlBase: String?, avTransportControl: String?
        private var text = "", serviceType = "", controlURL = "", inService = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""; if name == "service" { inService = true; serviceType = ""; controlURL = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "friendlyName" where friendlyName.isEmpty: friendlyName = value
            case "URLBase": urlBase = value
            case "serviceType" where inService: serviceType = value
            case "controlURL" where inService: controlURL = value
            case "service":
                if serviceType.contains("AVTransport"), avTransportControl == nil, !controlURL.isEmpty { avTransportControl = controlURL }
                inService = false
            default: break
            }
            text = ""
        }
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func metadata(title: String, artist: String, url: URL) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>\(escape(title))</dc:title><upnp:artist>\(escape(artist))</upnp:artist><upnp:class>object.item.audioItem.musicTrack</upnp:class><res protocolInfo=\"http-get:*:audio/mpeg:*\">\(escape(url.absoluteString))</res></item></DIDL-Lite>"
    }
    static func soap(_ action: String, _ arguments: [(String, String)]) -> (body: Data, soapAction: String) {
        let args = ([("InstanceID", "0")] + arguments).map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">\(args)</u:\(action)></s:Body></s:Envelope>"
        return (Data(body.utf8), "\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"")
    }
    /// 多数 DLNA 音箱不支持 HTTPS；网易云 CDN 同一路径的 http 地址可用。
    static func rendererFriendly(_ url: URL) -> URL {
        guard url.scheme == "https", let host = url.host, host.hasSuffix(".music.126.net") else { return url }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false); c?.scheme = "http"; return c?.url ?? url
    }
}

@MainActor final class UPnPController: ObservableObject {
    @Published private(set) var renderers: [UPnPRenderer] = []
    @Published private(set) var active: UPnPRenderer?
    @Published private(set) var status = ""
    @Published private(set) var searching = false
    var supported: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
    func discover() async {
        guard supported else { status = "iPhone 上搜索 DLNA 音箱需要 Apple 的多播权限，目前请在 Mac 上投放，或用 AirPlay。"; return }
        searching = true; status = "正在搜索局域网音箱…"
        let locations = await Task.detached { Self.ssdpSearch(seconds: 3) }.value
        var found: [UPnPRenderer] = []
        for location in Set(locations) {
            guard let (data, _) = try? await URLSession.shared.data(from: location), let r = UPnPProtocol.renderer(fromDescription: data, location: location), !found.contains(r) else { continue }
            found.append(r)
        }
        renderers = found.sorted { $0.name < $1.name }; searching = false
        status = found.isEmpty ? "没有找到支持 DLNA/UPnP 的音箱（需与这台 Mac 在同一网络）。" : "找到 \(found.count) 台音箱"
    }
    func cast(_ renderer: UPnPRenderer, url: URL, title: String, artist: String) async -> Bool {
        let target = UPnPProtocol.rendererFriendly(url)
        do {
            try await send(renderer, "SetAVTransportURI", [("CurrentURI", target.absoluteString), ("CurrentURIMetaData", UPnPProtocol.metadata(title: title, artist: artist, url: target))])
            try await send(renderer, "Play", [("Speed", "1")])
            active = renderer; status = "正在 \(renderer.name) 上播放《\(title)》"; return true
        } catch { status = "投放到 \(renderer.name) 失败：\(error.localizedDescription)"; return false }
    }
    func control(_ action: String) async {
        guard let active else { return }
        do { try await send(active, action, action == "Play" ? [("Speed", "1")] : []) } catch { status = "\(active.name) 没有响应：\(error.localizedDescription)" }
    }
    func disconnect() async { await control("Stop"); active = nil; status = "已切回本机播放" }
    private func send(_ renderer: UPnPRenderer, _ action: String, _ args: [(String, String)]) async throws {
        let soap = UPnPProtocol.soap(action, args)
        var request = URLRequest(url: renderer.controlURL); request.httpMethod = "POST"; request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type"); request.setValue(soap.soapAction, forHTTPHeaderField: "SOAPACTION")
        request.httpBody = soap.body
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { throw URLError(.badServerResponse) }
    }
    /// 发一次 M-SEARCH，在给定秒数内收集回应的 LOCATION。
    nonisolated static func ssdpSearch(seconds: Double) -> [URL] {
        #if os(macOS)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &address.sin_addr)
        let message = Array(UPnPProtocol.searchMessage.utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var found: [URL] = []
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { continue }
            if let url = UPnPProtocol.location(fromSSDP: String(decoding: buffer[0..<n], as: UTF8.self)), !found.contains(url) { found.append(url) }
        }
        return found
        #else
        return []
        #endif
    }
}
