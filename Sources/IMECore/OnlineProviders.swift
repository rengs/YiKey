import Foundation
import CryptoKit

// MARK: - HTTP 抽象（便于测试）

public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPFetching {
    public func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

public enum HTTPClient {
    public static let shared: HTTPFetching = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        return URLSession(configuration: cfg)
    }()
}

enum FormEncoder {
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func encode(_ items: [(String, String)]) -> Data {
        let s = items.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }
}

// MARK: - 百度翻译（国内可用，需自行申请 appid / 密钥）

public struct BaiduTranslateProvider: TranslationProvider {
    public let id = "baidu"
    let appID: String
    let secret: String
    let http: HTTPFetching
    let makeSalt: @Sendable () -> String

    public init(appID: String, secret: String,
                http: HTTPFetching = HTTPClient.shared,
                makeSalt: @escaping @Sendable () -> String = { String(Int.random(in: 100_000...999_999_999)) }) {
        self.appID = appID; self.secret = secret; self.http = http; self.makeSalt = makeSalt
    }

    public func isAvailable(from: TextLanguage, to: TextLanguage) async -> Bool {
        !appID.isEmpty && !secret.isEmpty
    }

    public func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String {
        let salt = makeSalt()
        let sign = Self.md5Hex(appID + text + salt + secret)
        var req = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = FormEncoder.encode([
            ("q", text), ("from", Self.code(from)), ("to", Self.code(to)),
            ("appid", appID), ("salt", salt), ("sign", sign),
        ])
        let (data, _) = try await http.fetch(req)
        return try Self.parse(data)
    }

    static func code(_ l: TextLanguage) -> String { l == .chinese ? "zh" : "en" }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.providerFailed("baidu: 响应不是 JSON")
        }
        if let code = obj["error_code"] {
            throw TranslationError.providerFailed("baidu \(code): \(obj["error_msg"] ?? "")")
        }
        guard let arr = obj["trans_result"] as? [[String: Any]] else {
            throw TranslationError.providerFailed("baidu: 缺少 trans_result")
        }
        return arr.compactMap { $0["dst"] as? String }.joined(separator: "\n")
    }
}

// MARK: - LibreTranslate（可自建服务，演示“换一个后端只需实现协议”）

public struct LibreTranslateProvider: TranslationProvider {
    public let id = "libretranslate"
    let baseURL: URL
    let apiKey: String?
    let http: HTTPFetching

    public init(baseURL: URL, apiKey: String? = nil, http: HTTPFetching = HTTPClient.shared) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.http = http
    }

    public func isAvailable(from: TextLanguage, to: TextLanguage) async -> Bool { true }

    public func translate(_ text: String, from: TextLanguage, to: TextLanguage) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("translate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = [
            "q": text, "source": from == .chinese ? "zh" : "en",
            "target": to == .chinese ? "zh" : "en", "format": "text",
        ]
        if let apiKey, !apiKey.isEmpty { body["api_key"] = apiKey }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await http.fetch(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = obj["translatedText"] as? String else {
            throw TranslationError.providerFailed("libretranslate: 响应无效")
        }
        return out
    }
}

// MARK: - 设置 & 工厂

/// 配置方式（IME 的 defaults 域 = Bundle ID）：
///   defaults write com.example.inputmethod.TranslateIME onlineFallbackEnabled -bool true
///   defaults write com.example.inputmethod.TranslateIME baiduAppID -string "xxx"
///   defaults write com.example.inputmethod.TranslateIME baiduSecret -string "yyy"
public enum IMESettings {
    public static let onlineFallbackEnabled = "onlineFallbackEnabled"
    public static let onlineProvider = "onlineProvider"        // "baidu"(默认) | "libretranslate"
    public static let baiduAppID = "baiduAppID"
    public static let baiduSecret = "baiduSecret"
    public static let libreURL = "libreTranslateURL"
    public static let libreAPIKey = "libreTranslateAPIKey"
    public static let debounceMs = "debounceMs"                // 防抖毫秒数，限制在 150–300，默认 200
    public static let latencyFileLog = "latencyFileLog"        // 开启文件延迟日志
    public static let latencyVerbose = "latencyVerbose"        // 记录每一次采样（默认只记慢事件与汇总）
    public static let pasteIntoComposition = "pasteIntoComposition"   // ⌘V 粘贴到英文组词并翻译（默认开）
    public static let autoSwitchPinyin = "autoSwitchPinyin"           // 翻译面板打开时自动切到简体拼音（默认开）
    public static let closeAfterCopy = "closeAfterCopy"               // ↩ 复制译文后自动关闭面板（默认开）
    public static let autoInsertAfterReturn = "autoInsertAfterReturn" // 回车后自动填入原输入框（默认开）
    public static let clipboardWatch = "clipboardWatch"               // 监测剪贴板英文并自动翻译（默认开）
    public static let clipboardPausedUntil = "clipboardPausedUntil"   // 暂停监测到某时刻（timeIntervalSince1970）

    /// 未设置时默认 true
    public static func flag(_ key: String, defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }

    public static func debounce(defaults: UserDefaults) -> TimeInterval {
        let ms = (defaults.object(forKey: debounceMs) as? Double) ?? 200
        return min(max(ms, 150), 300) / 1000
    }
}

public enum OnlineProviderFactory {
    /// 默认关闭：关闭或缺少凭据时返回空数组 → 绝不会把文本发到网络。
    public static func make(defaults: UserDefaults,
                            http: HTTPFetching = HTTPClient.shared) -> [TranslationProvider] {
        guard defaults.bool(forKey: IMESettings.onlineFallbackEnabled) else { return [] }
        switch defaults.string(forKey: IMESettings.onlineProvider) ?? "baidu" {
        case "libretranslate":
            guard let s = defaults.string(forKey: IMESettings.libreURL), let url = URL(string: s) else { return [] }
            return [LibreTranslateProvider(baseURL: url, apiKey: defaults.string(forKey: IMESettings.libreAPIKey), http: http)]
        default:
            let id = defaults.string(forKey: IMESettings.baiduAppID) ?? ""
            let secret = defaults.string(forKey: IMESettings.baiduSecret) ?? ""
            guard !id.isEmpty, !secret.isEmpty else { return [] }
            return [BaiduTranslateProvider(appID: id, secret: secret, http: http)]
        }
    }
}
