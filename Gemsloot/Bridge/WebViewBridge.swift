import Foundation
import WebKit

/// Builds the document-start user script that patches `fetch` / XHR for gemsloot `_api` traffic.
enum WebViewBridge {
    static let messageHandlerName = "gemslootBridge"

    struct Config: Encodable {
        var ffLockMode: String
        var deviceHeaderMode: String
        var deterministicBase36Hash: String
        var deterministicHex16: String
        var keychainUUID: String
        var lockedFfBodyJSON: String?
        var branchAPayload: [String: Any]
        var safeAreaTop: CGFloat

        enum CodingKeys: String, CodingKey {
            case ffLockMode, deviceHeaderMode, deterministicBase36Hash, deterministicHex16
            case keychainUUID, lockedFfBodyJSON, branchAPayload, safeAreaTop
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ffLockMode, forKey: .ffLockMode)
            try container.encode(deviceHeaderMode, forKey: .deviceHeaderMode)
            try container.encode(deterministicBase36Hash, forKey: .deterministicBase36Hash)
            try container.encode(deterministicHex16, forKey: .deterministicHex16)
            try container.encode(keychainUUID, forKey: .keychainUUID)
            try container.encodeIfPresent(lockedFfBodyJSON, forKey: .lockedFfBodyJSON)
            try container.encode(safeAreaTop, forKey: .safeAreaTop)
            try container.encode(AnyEncodable(branchAPayload), forKey: .branchAPayload)
        }
    }

    static func makeUserScript(config: Config) throws -> WKUserScript {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let configData = try encoder.encode(config)
        guard let configJSON = String(data: configData, encoding: .utf8) else {
            throw BridgeError.configEncodingFailed
        }
        let source = """
        (function() {
          'use strict';
          const config = \(configJSON);
          try {
            document.documentElement.style.setProperty('--safe-area', String(config.safeAreaTop || 0) + 'px');
          } catch (e) {}

          let lockedFfBodyJSON = (typeof config.lockedFfBodyJSON === 'string' && config.lockedFfBodyJSON.length)
            ? config.lockedFfBodyJSON
            : null;

          function postNative(msg) {
            try {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage(msg);
            } catch (e) {}
          }

          function isGemslootApiUrl(url) {
            return String(url).indexOf('gemsloot.com/_api') >= 0;
          }

          function isFfUrl(url) {
            try {
              const u = new URL(String(url), location.href);
              return /\\/_api\\/ff\\/?$/.test(u.pathname);
            } catch (e) {
              return /gemsloot\\.com\\/_api\\/ff\\/?([?#]|$)/.test(String(url));
            }
          }

          function headersToObject(headers) {
            const out = {};
            if (!headers) return out;
            if (typeof Headers !== 'undefined' && headers instanceof Headers) {
              headers.forEach(function(v, k) { out[k] = v; });
              return out;
            }
            if (Array.isArray(headers)) {
              headers.forEach(function(pair) {
                if (pair && pair.length >= 2) out[pair[0]] = pair[1];
              });
              return out;
            }
            if (typeof headers === 'object') {
              Object.keys(headers).forEach(function(k) { out[k] = headers[k]; });
            }
            return out;
          }

          function applyDeviceHeader(headerMap) {
            const mode = config.deviceHeaderMode;
            if (mode === 'ios') headerMap['Device'] = 'ios';
            else if (mode === 'android') headerMap['Device'] = 'android';
            else {
              delete headerMap['Device'];
              delete headerMap['device'];
            }
            return headerMap;
          }

          function processFfBody(rawBody) {
            const mode = config.ffLockMode || 'branchB_Locked';
            if (mode === 'passthrough') {
              return typeof rawBody === 'string' ? rawBody : JSON.stringify(rawBody || {});
            }
            if (mode === 'branchA_Capacitor') {
              return JSON.stringify(config.branchAPayload || {});
            }
            // Mode 1 — branchB_Locked
            if (lockedFfBodyJSON) {
              return lockedFfBodyJSON;
            }
            let obj = {};
            try {
              if (typeof rawBody === 'string' && rawBody.length) obj = JSON.parse(rawBody);
              else if (rawBody && typeof rawBody === 'object') obj = rawBody;
            } catch (e) { obj = {}; }
            obj.hash = config.deterministicBase36Hash;
            const snapshot = {
              hash: obj.hash,
              data: obj.data,
              formated_data: obj.formated_data
            };
            lockedFfBodyJSON = JSON.stringify(snapshot);
            postNative({ type: 'lockFfSnapshot', bodyJSON: lockedFfBodyJSON });
            return lockedFfBodyJSON;
          }

          function reportFf(url, bodyJSON, status) {
            postNative({
              type: 'ffTelemetry',
              url: String(url),
              bodyJSON: typeof bodyJSON === 'string' ? bodyJSON : JSON.stringify(bodyJSON || {}),
              status: typeof status === 'number' ? status : null
            });
          }

          // ---- fetch ----
          const originalFetch = window.fetch.bind(window);
          window.fetch = function(input, init) {
            init = init ? Object.assign({}, init) : {};
            let url = '';
            try {
              if (typeof input === 'string') url = input;
              else if (input && typeof input.url === 'string') url = input.url;
              else url = String(input);
            } catch (e) { url = String(input); }

            const api = isGemslootApiUrl(url);
            if (api) {
              init.credentials = 'include';
              let headerMap = headersToObject(init.headers);
              if (typeof Request !== 'undefined' && input instanceof Request) {
                headerMap = Object.assign(headersToObject(input.headers), headerMap);
              }
              headerMap = applyDeviceHeader(headerMap);
              init.headers = headerMap;

              if (isFfUrl(url) && String((init.method || (input && input.method) || 'GET')).toUpperCase() === 'POST') {
                let raw = init.body;
                if (raw == null && typeof Request !== 'undefined' && input instanceof Request) {
                  // Body may be locked on Request; best-effort from init only.
                  raw = init.body;
                }
                if (typeof raw !== 'string' && raw != null) {
                  try { raw = String(raw); } catch (e) { raw = ''; }
                }
                const processed = processFfBody(raw || '{}');
                init.body = processed;
                return originalFetch(input, init).then(function(response) {
                  reportFf(url, processed, response.status);
                  return response;
                });
              }
            }
            return originalFetch(input, init);
          };

          // ---- XMLHttpRequest ----
          const XHR = XMLHttpRequest.prototype;
          const originalOpen = XHR.open;
          const originalSend = XHR.send;
          const originalSetRequestHeader = XHR.setRequestHeader;

          XHR.open = function(method, url) {
            this.__gemsloot = {
              method: String(method || 'GET').toUpperCase(),
              url: String(url || ''),
              headers: {}
            };
            return originalOpen.apply(this, arguments);
          };

          XHR.setRequestHeader = function(name, value) {
            if (this.__gemsloot) {
              this.__gemsloot.headers[name] = value;
            }
            return originalSetRequestHeader.apply(this, arguments);
          };

          XHR.send = function(body) {
            const meta = this.__gemsloot || { method: 'GET', url: '', headers: {} };
            if (isGemslootApiUrl(meta.url)) {
              this.withCredentials = true;
              const headerMap = applyDeviceHeader(Object.assign({}, meta.headers));
              Object.keys(headerMap).forEach(function(k) {
                try { originalSetRequestHeader.call(this, k, headerMap[k]); } catch (e) {}
              }.bind(this));

              if (meta.method === 'POST' && isFfUrl(meta.url)) {
                const processed = processFfBody(typeof body === 'string' || body == null ? (body || '{}') : String(body));
                const xhr = this;
                xhr.addEventListener('loadend', function() {
                  reportFf(meta.url, processed, xhr.status);
                });
                return originalSend.call(this, processed);
              }
            }
            return originalSend.apply(this, arguments);
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    enum BridgeError: Error {
        case configEncodingFailed
    }
}

// MARK: - Type-erased encoding for [String: Any]

private struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init(_ value: Any) {
        encodeFunc = { encoder in
            try AnyEncodable.encode(value, to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }

    private static func encode(_ value: Any, to encoder: Encoder) throws {
        switch value {
        case let v as String:
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let v as Int:
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let v as Double:
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let v as Float:
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let v as Bool:
            var c = encoder.singleValueContainer()
            try c.encode(v)
        case let v as [String: Any]:
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (key, nested) in v {
                try c.encode(AnyEncodable(nested), forKey: DynamicKey(stringValue: key)!)
            }
        case let v as [Any]:
            var c = encoder.unkeyedContainer()
            for nested in v {
                try c.encode(AnyEncodable(nested))
            }
        case let v as NSNumber:
            var c = encoder.singleValueContainer()
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                try c.encode(v.boolValue)
            } else if floor(v.doubleValue) == v.doubleValue {
                try c.encode(v.intValue)
            } else {
                try c.encode(v.doubleValue)
            }
        case is NSNull:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        default:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
