import NetworkExtension
import OpenVPNAdapter
extension NEPacketTunnelFlow: OpenVPNAdapterPacketFlow {}

class PacketTunnelProvider: NEPacketTunnelProvider {
    
    lazy var vpnAdapter: OpenVPNAdapter = {
        let adapter = OpenVPNAdapter()
        adapter.delegate = self
        return adapter
    }()
    
    let vpnReachability = OpenVPNReachability()
    
    var sharedKey = "group.com." + "package.name"
    
    var startHandler: ((Error?) -> Void)?
    var stopHandler: (() -> Void)?
    var timerHandler: DispatchWorkItem?
    var startedTime: DispatchTime?
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
            guard
                let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
                let providerConfiguration = protocolConfiguration.providerConfiguration
            else {
                return
            }
            let ovpnFileContent: Data? = (providerConfiguration["ovpn"] as? String ?? "").data(using: .utf8);
            let configuration = OpenVPNConfiguration()
            configuration.fileContent = ovpnFileContent
            // Apply OpenVPN configuration
            let evaluation: OpenVPNConfigurationEvaluation
            do {
                evaluation = try vpnAdapter.apply(configuration: configuration)
            } catch {
                NSLog(error.localizedDescription);
                completionHandler(error)
                return
            }
            // Provide credentials if needed
            if !evaluation.autologin {
                guard let username: String = protocolConfiguration.username else {
                    return
                }
                let credentials = OpenVPNCredentials()
                credentials.username = username
                credentials.password = "Nan"
                
                do {
                    try vpnAdapter.provide(credentials: credentials)
                } catch {
                    completionHandler(error)
                    return
                }
            }
            let sharedDefault = UserDefaults(suiteName: sharedKey)!
            
            let myResult = sharedDefault.bool(forKey: "isAvailable");
            let timerLimit = sharedDefault.float(forKey: "endDateTime");
            let isPremium = sharedDefault.bool(forKey: "isPremium");
            if (myResult) {
                vpnReachability.startTracking { [weak self] status in
                    guard status == .reachableViaWiFi else { return }
                    self?.vpnAdapter.reconnect(afterTimeInterval: 5)
                }
                // Establish connection and wait for .connected event
                startHandler = completionHandler
                vpnAdapter.connect(using: packetFlow)
                if (!isPremium) {
                    timerHandler = DispatchWorkItem {
                        self.cancelTunnelWithError(nil)
                    }
                    if (timerLimit > 0) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(timerLimit) + 10.0, execute: timerHandler!)
                    }
                }
            }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopHandler = completionHandler
        if vpnReachability.isTracking {
            vpnReachability.stopTracking()
        }
        vpnAdapter.disconnect()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let handler = completionHandler {
            handler(messageData)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func wake() {
    }
    
}

extension PacketTunnelProvider: OpenVPNAdapterDelegate {
    
    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?, completionHandler: @escaping (Error?) -> Void) {
//        networkSettings?.dnsSettings?.matchDomains = [""]
        // Set the network settings for the current tunneling session.
        setTunnelNetworkSettings(networkSettings, completionHandler: completionHandler)
    }
    
    // Process events returned by the OpenVPN library
    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleEvent event: OpenVPNAdapterEvent, message: String?) {
        switch event {
        case .connected:
            if reasserting {
                reasserting = false
            }
            guard let startHandler = startHandler else { return }
            startHandler(nil)
            self.startHandler = nil
            self.startedTime = .now()
        case .disconnected:
            guard let stopHandler = stopHandler else { return }
            if vpnReachability.isTracking {
                vpnReachability.stopTracking()
            }
            stopHandler()
            self.stopHandler = nil
            if (timerHandler != nil) {
                if (!timerHandler!.isCancelled) {
                    timerHandler!.cancel()
                }
            }
        case .reconnecting:
            reasserting = true
        default:
            break
        }
    }
    
    // Handle errors thrown by the OpenVPN library
    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: Error) {
        // Handle only fatal errors
        guard let fatal = (error as NSError).userInfo[OpenVPNAdapterErrorFatalKey] as? Bool, fatal == true else {
            return
        }
        
        if vpnReachability.isTracking {
            vpnReachability.stopTracking()
        }
        
        if let startHandler = startHandler {
            startHandler(error)
            self.startHandler = nil
        } else {
            cancelTunnelWithError(error)
        }
    }
    
    // Use this method to process any log message returned by OpenVPN library.
    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        // Handle log messages
    }
}
