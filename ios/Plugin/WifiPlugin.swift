import Foundation
import Capacitor
import SystemConfiguration.CaptiveNetwork
import CoreLocation
import NetworkExtension

struct WifiEntry {
    var bssid: String
    var ssid: String = "[HIDDEN_SSID]"
    var level: Int = -1
    var isCurrentWify: Bool = false
    var capabilities: [String] = []
}

@objc(WifiPlugin)
public class WifiPlugin: CAPPlugin, CLLocationManagerDelegate {

    var _currentCall: CAPPluginCall?
    var _locationManager: CLLocationManager = CLLocationManager()

    private let wifi = Wifi()

    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        var locationState = "granted"

        if _currentCall == nil {
            return
        }

        let call: CAPPluginCall = _currentCall! as CAPPluginCall
        _currentCall = nil

        if status != .authorizedAlways && status != .authorizedWhenInUse {
            locationState = "denied"
        } else if status == .restricted {
            locationState = "prompt"
        }

        call.resolve([
            "LOCATION": locationState,
            "NETWORK": "granted"
        ])
    }

    @objc override public func checkPermissions(_ call: CAPPluginCall) {
        var locationState = "granted"

        let locationStatus = CLLocationManager.authorizationStatus()
        if locationStatus != .authorizedAlways && locationStatus != .authorizedWhenInUse {
            locationState = "denied"
        } else if locationStatus == .restricted {
            locationState = "prompt"
        }

        call.resolve([
            "LOCATION": locationState,
            "NETWORK": "granted"
        ])
    }

    @objc override public func requestPermissions(_ call: CAPPluginCall) {
        let locationStatus = CLLocationManager.authorizationStatus()
        if locationStatus != .authorizedAlways && locationStatus != .authorizedWhenInUse {
            _currentCall = call
            _locationManager.delegate = self
            _locationManager.requestWhenInUseAuthorization()
            return
        }

        call.resolve([
            "LOCATION": "granted",
            "NETWORK": "granted"
        ])
    }

    @objc func connectToWifiBySsidPrefixAndPassword(_ call: CAPPluginCall) {
        let ssidPrefix: String = call.getString("ssidPrefix", "")
        let _: String? = call.getString("password")

        print("[WifiPlugin] connectToWifiBySsidPrefixAndPassword called with prefix: \(ssidPrefix)")

        let hotspotConfig = NEHotspotConfiguration(ssidPrefix: ssidPrefix)
        hotspotConfig.joinOnce = true

        NEHotspotConfigurationManager.shared.apply(hotspotConfig) { error in
            if let error = error {
                print("[WifiPlugin] Connection error: \(error)")
                call.reject("MISSING_SSID_CONNECT_WIFI")
                return
            }
            
            print("[WifiPlugin] Connection successful, fetching current WiFi")
            self.fetchCurrentWifi { wifiEntry in
                call.resolve([
                    "wasSuccess": true,
                    "wifi": self.wifiEntryToWifiDict(wifiEntry: wifiEntry) as Any
                ])
            }
        }
    }

    @objc func connectToWifiBySsidAndPassword(_ call: CAPPluginCall) {
        let ssid = call.getString("ssid", "")
        let password = call.getString("password", "")
        
        print("[WifiPlugin] connectToWifiBySsidAndPassword called with ssid: \(ssid)")
        
        let hotspotConfig = NEHotspotConfiguration(
            ssid: ssid,
            passphrase: password,
            isWEP: false
        )

        NEHotspotConfigurationManager.shared.apply(hotspotConfig) { error in
            if let error = error {
                print("[WifiPlugin] Connection error: \(error)")
            } else {
                print("[WifiPlugin] Connection successful")
            }
            call.resolve(["wasSuccess": true])
        }
    }

    @objc func scanWifi(_ call: CAPPluginCall) {
        print("[WifiPlugin] scanWifi called")
        
        fetchCurrentWifi { wifiEntry in
            if let wifiEntry = wifiEntry {
                print("[WifiPlugin] Current WiFi: SSID=\(wifiEntry.ssid), BSSID=\(wifiEntry.bssid)")
                var wifis: [[String: Any]] = []
                if let wifiDict = self.wifiEntryToWifiDict(wifiEntry: wifiEntry) {
                    wifis.append(wifiDict)
                }
                print("[WifiPlugin] Resolved with \(wifis.count) WiFi network(s)")
                call.resolve(["wifis": wifis] as PluginCallResultData)
            } else {
                print("[WifiPlugin] No current WiFi connection found")
                call.resolve(["wifis": [] as [String]])
            }
        }
    }

    @objc func getCurrentWifi(_ call: CAPPluginCall) {
        print("[WifiPlugin] getCurrentWifi called")
        
        fetchCurrentWifi { wifiEntry in
            if let wifiEntry = wifiEntry {
                print("[WifiPlugin] Current WiFi: SSID=\(wifiEntry.ssid), BSSID=\(wifiEntry.bssid)")
                call.resolve(["currentWifi": self.wifiEntryToWifiDict(wifiEntry: wifiEntry) as Any])
            } else {
                print("[WifiPlugin] No current WiFi connection found")
                call.resolve(["currentWifi": ""])
            }
        }
    }

    private func fetchCurrentWifi(completion: @escaping (WifiEntry?) -> Void) {
        print("[WifiPlugin] fetchCurrentWifi called (using NEHotspotNetwork)")
        
        NEHotspotNetwork.fetchCurrent { network in
            if let network = network {
                print("[WifiPlugin] NEHotspotNetwork success - SSID: \(network.ssid), BSSID: \(network.bssid)")
                let wifiEntry = WifiEntry(
                    bssid: network.bssid,
                    ssid: network.ssid,
                    isCurrentWify: true
                )
                completion(wifiEntry)
            } else {
                print("[WifiPlugin] NEHotspotNetwork returned nil, trying legacy CNCopyCurrentNetworkInfo")
                completion(self.getCurrentWifiInfoLegacy())
            }
        }
    }

    private func getCurrentWifiInfoLegacy() -> WifiEntry? {
        print("[WifiPlugin] getCurrentWifiInfoLegacy called")
        
        guard let interfaces = CNCopySupportedInterfaces() as NSArray? else {
            print("[WifiPlugin] No supported interfaces available")
            return nil
        }
        
        print("[WifiPlugin] Found \(interfaces.count) network interface(s)")
        
        for interface in interfaces {
            print("[WifiPlugin] Checking interface: \(interface)")
            
            if let interfaceInfo = CNCopyCurrentNetworkInfo(interface as! CFString) as NSDictionary? {
                let bssid = interfaceInfo[kCNNetworkInfoKeyBSSID as String] as? String ?? ""
                let ssid = interfaceInfo[kCNNetworkInfoKeySSID as String] as? String ?? "[HIDDEN_SSID]"
                
                print("[WifiPlugin] Legacy API success - BSSID: \(bssid), SSID: \(ssid)")
                
                return WifiEntry(
                    bssid: bssid,
                    ssid: ssid,
                    isCurrentWify: true
                )
            } else {
                print("[WifiPlugin] Failed to retrieve network info for interface: \(interface)")
            }
        }
        
        print("[WifiPlugin] No active WiFi connection found across all interfaces")
        return nil
    }

    func wifiEntryToWifiDict(wifiEntry: WifiEntry?) -> [String: Any]? {
        guard let wifiEntry = wifiEntry else {
            return nil
        }

        return [
            "bssid": wifiEntry.bssid,
            "ssid": wifiEntry.ssid,
            "isCurrentWifi": wifiEntry.isCurrentWify,
            "level": -1,
            "capabilities": [String]()
        ] as [String: Any]
    }
}
