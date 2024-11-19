//
//  ContentView.swift
//  PomeloRPC
//
//  Created by Stossy11 on 16/11/2024.
//

import SwiftUI
import SwordRPC
import FlyingFox
import AppKit
import Foundation
import AppKit

struct ContentView: View {
    @StateObject var discordRPCServer = DiscordRPCServer()
    @State var serverstarted: Bool = false
    var body: some View {
        VStack {
            Text("PomeloRPC")
                .font(.largeTitle)
            Text("Server Address: \( "http://" + (getLocalIPAddress() ?? " Unable to get local IP ")):8080")
                .font(.title)
            Divider()
            if let game = discordRPCServer.currentGame {
                Text("Current Game")
                    .font(.largeTitle)
                Text(game.name + " (\(game.id))")
                    .font(.title)
                Text(game.developer)
            }
            if serverstarted {
                Button {
                    do {
                        serverstarted = try discordRPCServer.start()
                    } catch {
                        print(error)
                    }
                } label: {
                    Text("Start Pomelo RPC")
                }
                .disabled(true)
            } else {
                Button {
                    do {
                        serverstarted = try discordRPCServer.start()
                    } catch {
                        print(error)
                    }
                } label: {
                    Text("Start Pomelo RPC")
                }
            }
        }
        .padding()
    }
}

struct Game: Codable {
    let name: String
    let id: String
    let developer: String
}


func getLocalIPAddress() -> String? {
    var address: String?

    // Get the list of all interfaces on the device
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
        return nil
    }
    
    // Iterate through linked list of interfaces
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ptr.pointee
        
        // Check for IPv4 and Wi-Fi/Ethernet
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) { // AF_INET = IPv4
            _ = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addr = interface.ifa_addr
            if getnameinfo(addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
            }
        }
    }
    
    freeifaddrs(ifaddr)
    return address
}



class DiscordRPCServer: ObservableObject {
    @Published private(set) var isConnected = false
    @State public var currentGame: Game?
    
    @State private var sword: SwordRPC
    @State private var server: HTTPServer
    
    // Heartbeat management
    private var heartbeatMonitor: Task<Void, Never>?
    private var lastHeartbeatTime: Date?
    private let heartbeatLock = NSLock()
    
    // Configuration
    private let config = HeartbeatConfig(
        checkInterval: 1.0,    // Check heartbeat every 1 second
        gracePeriod: 10.0,      // Allow 5 seconds without heartbeat before disconnecting
        warningThreshold: 3.0   // Log warning if no heartbeat for 3 seconds
    )
    
    private struct HeartbeatConfig {
        let checkInterval: TimeInterval
        let gracePeriod: TimeInterval
        let warningThreshold: TimeInterval
    }
    
    init(appId: String = "1134677489713684531", port: Int = 8080) {
        self.sword = SwordRPC(appId: appId)
        self.server = HTTPServer(port: UInt16(port))
        
        Task {
            await setupWebServer()
        }
    }
    
    // MARK: - Public Interface
    
    func start() throws -> Bool {
        // Start the HTTP server
        Task {
            try await server.run()
        }
        // Connect to Discord
        if isConnected {
            isConnected = true
            
            // Set initial empty presence
            let emptyPresence = RichPresence()
            sword.setPresence(emptyPresence)
        }
        
        return true
    }
    
    func stop() {
        stopHeartbeatMonitoring()
        resetPresence()
        sword.disconnect()
        isConnected = false
        currentGame = nil
    }
    
    // MARK: - Private Methods
    
    private func setupWebServer() async {
        // Route: Start RPC
        await server.appendRoute("/start-rpc") { [weak self] request in
            guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
            guard request.method.rawValue == "POST" else {
                return HTTPResponse(statusCode: .methodNotAllowed)
            }
            
            do {
                let game = try await self.decodeGameFromRequest(request)
                await self.handleGameStart(game)
                return HTTPResponse(statusCode: .ok)
            } catch {
                print("Failed to start RPC: \(error.localizedDescription)")
                return HTTPResponse(statusCode: .badRequest)
            }
        }
        
        // Route: Heartbeat
        await server.appendRoute("/heartbeat") { [weak self] request in
            guard let self = self else { return HTTPResponse(statusCode: .internalServerError) }
            self.updateHeartbeat()
            return HTTPResponse(statusCode: .ok)
        }
    }
    
    private func decodeGameFromRequest(_ request: HTTPRequest) async throws -> Game {
        guard let bodyData = try? await request.bodyData,
              let bodyString = String(data: bodyData, encoding: .utf8),
              let gameData = bodyString.data(using: .utf8) else {
            throw HeartbeatError.invalidRequestData
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(Game.self, from: gameData)
    }
    
    private func handleGameStart(_ game: Game) async {
        DispatchQueue.main.async {
            self.currentGame = game
        }
        
        // Configure rich presence
        var rpc = RichPresence()
        rpc.details = "Playing: \(game.name) (\(game.id))"
        if #available(macOS 12, *) {
            rpc.timestamps.start = .now
        } else {
            rpc.timestamps.start = Date()
        }
        rpc.state = game.developer
        rpc.assets.largeImage = "pomelo-icon"
        rpc.assets.largeText = "Pomelo Emulator"
        
        sword.setPresence(rpc)
        
        // Start heartbeat monitoring
        
        isConnected = sword.connect()
        
        updateHeartbeat()
        startHeartbeatMonitoring()
    }
    
    private func updateHeartbeat() {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        lastHeartbeatTime = Date()
    }
    
    private func startHeartbeatMonitoring() {
        stopHeartbeatMonitoring() // Ensure any existing monitor is stopped
        
        heartbeatMonitor = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(config.checkInterval * 1_000_000_000))
                    
                    let shouldDisconnect = await self.checkHeartbeat()
                    if shouldDisconnect {
                        await self.handleDisconnection()
                        break
                    }
                } catch {
                    print("Heartbeat monitoring error: \(error.localizedDescription)")
                    break
                }
            }
        }
    }
    
    private func checkHeartbeat() async -> Bool {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        
        guard let lastHeartbeat = lastHeartbeatTime else {
            return true // No heartbeat ever received
        }
        
        let timeSinceLastHeartbeat = Date().timeIntervalSince(lastHeartbeat)
        
        if timeSinceLastHeartbeat >= config.gracePeriod {
            print("⚠️ No heartbeat received for \(String(format: "%.1f", timeSinceLastHeartbeat)) seconds. Disconnecting...")
            return true
        } else if timeSinceLastHeartbeat >= config.warningThreshold {
            print("⚠️ Warning: No heartbeat for \(String(format: "%.1f", timeSinceLastHeartbeat)) seconds")
        }
        
        return false
    }
    
    private func handleDisconnection() async {
        resetPresence()
        currentGame = nil
        self.stop()
    }
    
    private func stopHeartbeatMonitoring() {
        heartbeatMonitor?.cancel()
        heartbeatMonitor = nil
    }
    
    private func resetPresence() {
        sword.setPresence(RichPresence())
    }
}

// MARK: - Error Handling

enum HeartbeatError: Error {
    case invalidRequestData
    case decodingError
    case heartbeatTimeout
}
