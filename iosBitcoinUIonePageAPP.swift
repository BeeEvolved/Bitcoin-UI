import SwiftUI
import Combine
import Security
import Foundation
import UIKit


struct HighlightableText: View {
    let text: String
    @State private var isHighlighted = false
    var body: some View {
        Text(text)
            .padding(4)
            .background(isHighlighted ? Color.yellow.opacity(0.4) : Color.clear)
            .cornerRadius(4)
            .onTapGesture {
                withAnimation { isHighlighted.toggle() }
                UIPasteboard.general.string = text
            }
    }
}


class KeychainHelper {
    static let shared = KeychainHelper()
    func save(_ service: String, account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil)
    }
    func read(_ service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == noErr { return dataTypeRef as? Data }
        return nil
    }
    func delete(_ service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
    func saveCredentials(username: String, password: String) {
        if let u = username.data(using: .utf8), let p = password.data(using: .utf8) {
            _ = save("BitcoinNodeRPC", account: "username", data: u)
            _ = save("BitcoinNodeRPC", account: "password", data: p)
        }
    }
    func loadCredentials() -> (username: String, password: String)? {
        guard let u = read("BitcoinNodeRPC", account: "username"),
              let p = read("BitcoinNodeRPC", account: "password"),
              let user = String(data: u, encoding: .utf8),
              let pass = String(data: p, encoding: .utf8) else { return nil }
        return (user, pass)
    }
    func clearCredentials() {
        delete("BitcoinNodeRPC", account: "username")
        delete("BitcoinNodeRPC", account: "password")
    }
}


class RPCService {
    var nodeAddress: String
    var rpcPort: String
    var rpcUser: String
    var rpcPassword: String
    init(nodeAddress: String, rpcPort: String, rpcUser: String, rpcPassword: String) {
        self.nodeAddress = nodeAddress
        self.rpcPort = rpcPort
        self.rpcUser = rpcUser
        self.rpcPassword = rpcPassword
    }
    func sendRPC(method: String, params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = URL(string: "http://\(nodeAddress):\(rpcPort)") else {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = "\(rpcUser):\(rpcPassword)"
        guard let credData = credentials.data(using: .utf8) else {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Error encoding credentials"])))
            }
            return
        }
        request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["jsonrpc": "1.0", "id": "swift-ui", "method": method, "params": params]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let completeOnMain: (Result<Any, Error>) -> Void = { result in
                if Thread.isMainThread { completion(result) }
                else { DispatchQueue.main.async { completion(result) } }
            }
            if let error = error { completeOnMain(.failure(error)); return }
            guard let data = data else {
                completeOnMain(.failure(NSError(domain:"", code: 0, userInfo: [NSLocalizedDescriptionKey:"No data received."])))
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data)
                completeOnMain(.success(json))
            } catch { completeOnMain(.failure(error)) }
        }.resume()
    }
}


struct BlockInfo: Identifiable, Equatable { var id: String { hash }
    let height: Int; let hash: String; let time: Int
}
struct BlockCandidate: Identifiable { var id: String { "next" }
    let mempoolTxCount: Int; let estimatedFee: Double?
}
struct TransactionModel: Identifiable, Hashable {
    var id: String { txid }
    let txid: String; let amount: Double; let confirmations: Int; let walletName: String
}
struct WalletAddress: Identifiable, Equatable {
    let id = UUID(); let address: String; var label: String?; var balance: Double?; var isUsed: Bool
}
class WalletModel: Identifiable, ObservableObject, Hashable {
    static func == (lhs: WalletModel, rhs: WalletModel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID = UUID()
    @Published var name: String
    @Published var defaultAddressType: String = "bech32" // per-wallet preference
    @Published var usedAddresses: Set<String> = []
    @Published var addresses: [WalletAddress] = []
    @Published var balanceBTC: Double? = nil            // Wallet-level balance for list view
    init(name: String) { self.name = name }
}
struct MempoolEntry: Identifiable, Equatable { var id: String { txid }
    let txid: String; let fee: Double; let size: Int
}


struct AnimatedNextBlockView: View {
    let mempoolEntries: [MempoolEntry]
    let onSelect: (MempoolEntry) -> Void
    @State private var packedPositions: [String: CGPoint] = [:]
    @State private var offsets: [String: CGFloat] = [:]
    @State private var opacities: [String: Double] = [:]
    @State private var timer: Timer? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange, lineWidth: 3)
                    .frame(width: geo.size.width, height: geo.size.height)
                ForEach(mempoolEntries) { entry in
                    if let position = packedPositions[entry.id] {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(colorForSize(size: txSize(for: entry)))
                            .frame(width: txSize(for: entry), height: txSize(for: entry))
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 2)
                            .position(CGPoint(x: position.x, y: position.y + (offsets[entry.id] ?? 0)))
                            .opacity(opacities[entry.id] ?? 1)
                            .transition(.opacity)
                            .onTapGesture { onSelect(entry) }
                    }
                }
            }
        }
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            packedPositions = computePackedPositions(for: mempoolEntries, containerSize: CGSize(width: 300, height: 300))
            animateEntries()
            timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
                offsets = [:]; opacities = [:]; packedPositions = [:]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    packedPositions = computePackedPositions(for: mempoolEntries, containerSize: CGSize(width: 300, height: 300))
                    animateEntries()
                }
            }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
        .onChange(of: mempoolEntries) { oldValue, newValue in
            packedPositions = computePackedPositions(for: newValue, containerSize: CGSize(width: 300, height: 300))
            animateEntries()
        }
    }

    private func animateEntries() {
        for (index, entry) in mempoolEntries.enumerated() {
            offsets[entry.id] = -50 - CGFloat(index * 10)
            opacities[entry.id] = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    offsets[entry.id] = 0; opacities[entry.id] = 1
                }
            }
        }
    }
    private func computePackedPositions(for entries: [MempoolEntry], containerSize: CGSize) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:], rows: [[MempoolEntry]] = [], currentRow: [MempoolEntry] = []; var currentWidth: CGFloat = 0
        for entry in entries {
            let s = txSize(for: entry)
            if currentWidth + s > containerSize.width {
                if !currentRow.isEmpty { rows.append(currentRow) }
                currentRow = []; currentWidth = 0
            }
            currentRow.append(entry); currentWidth += s
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        var y: CGFloat = containerSize.height
        for row in rows.reversed() {
            let maxH = row.map { txSize(for: $0) }.max() ?? 0
            var x: CGFloat = 0
            for entry in row {
                let s = txSize(for: entry)
                positions[entry.id] = CGPoint(x: x + s/2, y: y - maxH/2)
                x += s
            }
            y -= maxH
        }
        return positions
    }
    private func colorForSize(size: CGFloat) -> Color {
        let saturation: Double = (size == 10 ? 0.5 : size == 25 ? 0.75 : 1.0)
        return Color(hue: 0.08, saturation: saturation, brightness: 1.0)
    }
    private func txSize(for entry: MempoolEntry) -> CGFloat {
        if entry.size < 200 { return 10 } else if entry.size < 500 { return 25 } else { return 40 }
    }
}


struct TransactionDetailsView: View {
    let details: [String: Any]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(details.keys.sorted(), id: \.self) { key in
                DetailView(key: key, value: details[key]!)
            }
        }
        .padding()
    }
}
struct DetailView: View {
    let key: String?
    let value: Any
    var body: some View {
        Group {
            if let dict = value as? [String: Any] {
                VStack(alignment: .leading, spacing: 4) {
                    if let key = key { HighlightableText(text: "\(key):").font(.headline) }
                    ForEach(dict.keys.sorted(), id: \.self) { subkey in
                        DetailView(key: subkey, value: dict[subkey]!).padding(.leading, 10)
                    }
                }
            } else if let array = value as? [Any] {
                VStack(alignment: .leading, spacing: 4) {
                    if let key = key { HighlightableText(text: "\(key):").font(.headline) }
                    ForEach(0..<array.count, id: \.self) { index in
                        DetailView(key: "Item \(index + 1)", value: array[index]).padding(.leading, 10)
                    }
                }
            } else {
                if let key = key { HighlightableText(text: "\(key): \(formattedValue(for: key, value: value))") }
                else { HighlightableText(text: "\(formattedValue(for: "", value: value))") }
            }
        }
    }
}
func formattedValue(for key: String, value: Any) -> String {
    if key.lowercased().contains("time"), let i = value as? Int {
        let date = Date(timeIntervalSince1970: TimeInterval(i))
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: date)
    } else { return String(describing: value) }
}


class BitcoinNodeViewModel: ObservableObject {
    
    @Published var nodeAddress: String = ""
    @Published var rpcPort: String = "8332"
    @Published var rpcUser: String = ""
    @Published var rpcPassword: String = ""
    @Published var isConnected: Bool = false
    @Published var blockHeight: String = "--"
    @Published var mempoolSize: String = "--"
    @Published var peersConnected: String = "--"
    @Published var syncStatus: String = "--"
    @Published var walletBalance: String = "--"

    
    @Published var recentBlocks: [BlockInfo] = []
    @Published var nextBlockCandidate: BlockCandidate? = nil

   
    @Published var recipientAddress: String = ""
    @Published var amountBTC: String = ""
    @Published var generatedAddress: String = ""
    @Published var transactions: [TransactionModel] = []

    
    @Published var rpcResponse: String = "RPC response will appear here..."
    @Published var rpcCommand: String = "getblockchaininfo"

 
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var showAlert: Bool = false
    @Published var rememberMe: Bool = false
    @Published var privacyMode: Bool = false

   
    @Published var wallets: [WalletModel] = []
    @Published var selectedWallet: WalletModel? = nil

  
    @Published var selectedAddressType: String = "bech32" // receiving/generation format
    @Published var newWalletPreferredType: String = "bech32" // chosen during wallet creation

    
    @Published var nodeHistory: [String] = []

   
    @Published var mempoolTransactions: [String] = []
    @Published var mempoolEntries: [MempoolEntry] = []

    
    @Published var liveLowSatVb: Double?
    @Published var liveStdSatVb: Double?
    @Published var liveHighSatVb: Double?
    @Published var liveFeeUpdatedAt: Date?
    @Published var liveFeeActive: Bool = false

    
    enum FeeOption: String, CaseIterable, Identifiable { var id: String { rawValue }
        case low = "Low", standard = "Standard", high = "High", custom = "Custom"
    }
    @Published var feeOption: FeeOption = .standard              // for Send flow
    @Published var customFeeRate: String = ""                    // for Send flow (BTC/kB)
    @Published var sweepFeeOption: FeeOption = .standard         // for Sweep flow
    @Published var sweepCustomFeeRate: String = ""               // for Sweep flow (BTC/kB)

    var rpcService: RPCService? = nil

   
    var blockPollingTimer: AnyCancellable?
    var mempoolPollingTimer: AnyCancellable?
    var transactionPollingTimer: AnyCancellable?
    var statusPollingTimer: AnyCancellable?
    var feePollingTimer: AnyCancellable?

    enum TransactionSendStatus { case idle, processing, success(txid: String), failure(reason: String) }
    @Published var transactionSendStatus: TransactionSendStatus = .idle

    
    func btcPerKBToSatPerVB(_ rate: Double) -> Double { rate * 100_000_000.0 / 1000.0 }
    func satPerVBToBtcPerKB(_ sat: Double) -> Double { sat * 1000.0 / 100_000_000.0 }

    init() {
        if let currentNode = UserDefaults.standard.string(forKey: "CurrentNode") {
            nodeAddress = currentNode
            if let port = UserDefaults.standard.string(forKey: "CurrentNodePort") { rpcPort = port }
            if let credentials = KeychainHelper.shared.loadCredentials() {
                rpcUser = credentials.username; rpcPassword = credentials.password; rememberMe = true
                connectToNode()
            }
        }
        nodeHistory = UserDefaults.standard.stringArray(forKey: "NodeHistory") ?? []
    }

    
    func refreshDynamicFees() {
        guard isConnected, let rpc = rpcService else { return }

        func toSatVb(_ btcPerKvB: Double) -> Double { btcPerKvB * 100_000_000.0 / 1000.0 }

        let group = DispatchGroup()
        var low: Double?
        var std: Double?
        var high: Double?

        func fetchSmartFee(target: Int, modes: [String], done: @escaping (Double?) -> Void) {
            var idx = 0
            func tryNext() {
                if idx >= modes.count { done(nil); return }
                let mode = modes[idx]; idx += 1
                rpc.sendRPC(method: "estimatesmartfee", params: [target, mode]) { result in
                    switch result {
                    case .success(let json):
                        if let d = json as? [String: Any],
                           let res = d["result"] as? [String: Any],
                           let btcPerKvB = res["feerate"] as? Double {
                            done(toSatVb(btcPerKvB))
                        } else { tryNext() }
                    case .failure:
                        tryNext()
                    }
                }
            }
            tryNext()
        }

        group.enter(); fetchSmartFee(target: 18, modes: ["ECONOMICAL","CONSERVATIVE"]) { v in low = v; group.leave() }
        group.enter(); fetchSmartFee(target: 6,  modes: ["CONSERVATIVE","ECONOMICAL"]) { v in std = v; group.leave() }
        group.enter(); fetchSmartFee(target: 2,  modes: ["CONSERVATIVE","ECONOMICAL"]) { v in high = v; group.leave() }

        group.notify(queue: .main) {
            rpc.sendRPC(method: "getmempoolinfo", params: []) { result in
                var base: Double = 1.0
                if case .success(let j) = result,
                   let d = j as? [String: Any],
                   let r = d["result"] as? [String: Any],
                   let mempoolMinBtcKvB = r["mempoolminfee"] as? Double {
                    base = toSatVb(mempoolMinBtcKvB)
                    if base < 1.0 { base = 1.0 }
                }
                var S0 = std ?? max((low ?? base) * 1.8, base + 2.0)
                let L0 = low ?? max(S0 * 0.6, base + 1.0)
                var H0 = high ?? max(S0 * 1.25, S0 + 1.0)
                if S0 <= L0 { S0 = max(L0 * 1.15, L0 + 1.0) }
                if H0 <= S0 { H0 = max(S0 * 1.15, S0 + 1.0) }
                self.liveLowSatVb = L0
                self.liveStdSatVb = S0
                self.liveHighSatVb = H0
                self.liveFeeUpdatedAt = Date()
                self.liveFeeActive = true
            }
        }
    }

    func startFeePolling() {
        feePollingTimer?.cancel()
        feePollingTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshDynamicFees()
        }
    }
    func stopFeePolling() { feePollingTimer?.cancel(); feePollingTimer = nil }

    
    func fetchMempoolTransactions() {
        rpcService?.sendRPC(method: "getrawmempool", params: [true]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let resultDict = dict["result"] as? [String: [String: Any]] {
                    var entries: [MempoolEntry] = []
                    for (txid, info) in resultDict {
                        var fee: Double?
                        if let fees = info["fees"] as? [String: Any], let baseFee = fees["base"] as? Double { fee = baseFee }
                        else if let baseFee = info["fee"] as? Double { fee = baseFee }
                        if let fee = fee, let size = info["vsize"] as? Int {
                            entries.append(MempoolEntry(txid: txid, fee: fee, size: size))
                        }
                    }
                    entries.sort { ($0.fee / Double($0.size)) > ($1.fee / Double($1.size)) }
                    self.mempoolEntries = Array(entries.prefix(50))
                    self.mempoolTransactions = self.mempoolEntries.map { $0.txid }
                    self.nextBlockCandidate = BlockCandidate(mempoolTxCount: resultDict.count, estimatedFee: nil)
                }
            case .failure(let error):
                print("Error fetching mempool transactions: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription; self.showAlert = true
            }
        }
    }

    
    func purgeAllData() {
        disconnectNode()
        wallets = []; selectedWallet = nil
        transactions = []; generatedAddress = ""
        recipientAddress = ""; amountBTC = ""
        recentBlocks = []; nextBlockCandidate = nil
        rpcResponse = ""; rpcCommand = "getblockchaininfo"
        KeychainHelper.shared.clearCredentials()
        purgeNodeHistory()
    }

    func connectToNode() {
        self.rpcService = RPCService(nodeAddress: nodeAddress, rpcPort: rpcPort, rpcUser: rpcUser, rpcPassword: rpcPassword)
        isLoading = true
        rpcService?.sendRPC(method: "getblockchaininfo", params: []) { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
            case .success(let json):
                if let jsonDict = json as? [String: Any], jsonDict["result"] != nil {
                    self.isConnected = true
                    self.rpcResponse = "Successfully connected to your Bitcoin node!"
                    if self.rememberMe { KeychainHelper.shared.saveCredentials(username: self.rpcUser, password: self.rpcPassword) }
                    UserDefaults.standard.set(self.nodeAddress, forKey: "CurrentNode")
                    UserDefaults.standard.set(self.rpcPort, forKey: "CurrentNodePort")
                    self.refreshNodeInfo()
                    self.fetchRecentBlocks()
                    self.listWalletsFromNode()
                    self.addNodeToHistory(node: self.nodeAddress)
                    self.fetchMempoolTransactions()
                    self.refreshDynamicFees()
                    self.startFeePolling()
                    self.blockPollingTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { _ in self.fetchRecentBlocks() }
                    self.mempoolPollingTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { _ in self.fetchMempoolTransactions() }
                    self.transactionPollingTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { _ in
                        self.fetchTransactions(); self.fetchBalance(); self.fetchAddressesBalances(); self.fetchAllWalletAddresses()
                        self.fetchBalancesForWalletList()
                    }
                    self.statusPollingTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { _ in self.refreshNodeInfo() }
                } else {
                    self.isConnected = false
                    self.rpcResponse = "Failed to connect to Bitcoin node."
                    self.errorMessage = "Invalid response from node."; self.showAlert = true
                }
            case .failure(let error):
                self.isConnected = false
                self.rpcResponse = "Failed to connect to Bitcoin node: \(error.localizedDescription)."
                self.errorMessage = error.localizedDescription; self.showAlert = true
            }
        }
    }

    func disconnectNode() {
        isConnected = false
        blockHeight = "--"; mempoolSize = "--"; peersConnected = "--"; syncStatus = "--"; walletBalance = "--"
        rpcResponse = "Disconnected from your Bitcoin node."
        recentBlocks = []; nextBlockCandidate = nil; transactions = []
        blockPollingTimer?.cancel(); mempoolPollingTimer?.cancel(); transactionPollingTimer?.cancel(); statusPollingTimer?.cancel()
        stopFeePolling()
    }

    func refreshNodeInfo() {
        guard isConnected else { return }
        isLoading = true
        let group = DispatchGroup()

        group.enter()
        rpcService?.sendRPC(method: "getblockchaininfo", params: []) { [weak self] result in
            if case .success(let json) = result,
               let dict = json as? [String: Any],
               let resultDict = dict["result"] as? [String: Any] {
                if let blocks = resultDict["blocks"] { self?.blockHeight = "\(blocks)" }
                if let progress = resultDict["verificationprogress"] as? Double { self?.syncStatus = String(format: "%.2f%%", progress * 100) }
            }
            group.leave()
        }
        group.enter()
        rpcService?.sendRPC(method: "getnetworkinfo", params: []) { [weak self] result in
            if case .success(let json) = result,
               let dict = json as? [String: Any],
               let resultDict = dict["result"] as? [String: Any],
               let connections = resultDict["connections"] as? Int {
                self?.peersConnected = "\(connections)"
            }
            group.leave()
        }
        group.enter()
        rpcService?.sendRPC(method: "getmempoolinfo", params: []) { [weak self] result in
            if case .success(let json) = result,
               let dict = json as? [String: Any],
               let resultDict = dict["result"] as? [String: Any],
               let size = resultDict["size"] as? Int {
                self?.mempoolSize = "\(size)"
            }
            group.leave()
        }
        group.notify(queue: .main, execute: {
            self.isLoading = false
            if !self.privacyMode { self.fetchBalance() }
        })
    }

   
    func fetchBalance() {
        guard isConnected, selectedWallet != nil else { return }
        isLoading = true
        sendWalletRPC(method: "getbalance", params: []) { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let balance = dict["result"] as? Double {
                    self.walletBalance = String(format: "%.8f", balance)
                    if let name = self.selectedWallet?.name, let idx = self.wallets.firstIndex(where: { $0.name == name }) {
                        self.wallets[idx].balanceBTC = balance
                    }
                } else { self.walletBalance = "0.00000000" }
            case .failure(let error):
                self.walletBalance = "Error: \(error.localizedDescription)"
            }
        }
    }

    func fetchRecentBlocks() {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "getblockcount", params: []) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any],
                   let count = dict["result"] as? Int {
                    let previousHeight = Int(self.blockHeight) ?? 0
                    if count > previousHeight { self.nextBlockFilled() }
                    var blocks: [BlockInfo] = []
                    let group = DispatchGroup()
                    let start = max(0, count - 9)
                    for height in start...count {
                        group.enter()
                        rpcService.sendRPC(method: "getblockhash", params: [height]) { res in
                            if case .success(let hashJson) = res,
                               let hashDict = hashJson as? [String: Any],
                               let hash = hashDict["result"] as? String {
                                rpcService.sendRPC(method: "getblock", params: [hash]) { blockRes in
                                    if case .success(let blockJson) = blockRes,
                                       let blockDict = blockJson as? [String: Any],
                                       let blockResult = blockDict["result"] as? [String: Any],
                                       let time = blockResult["time"] as? Int {
                                        let info = BlockInfo(height: height, hash: hash, time: time)
                                        blocks.append(info)
                                    }
                                    group.leave()
                                }
                            } else { group.leave() }
                        }
                    }
                    group.notify(queue: .main, execute: {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            self.recentBlocks = blocks.sorted { $0.height > $1.height }
                        }
                    })
                }
            case .failure(let error):
                print("Error fetching block count: \(error.localizedDescription)")
            }
        }
    }

    func nextBlockFilled() {
        mempoolEntries = []
        fetchRecentBlocks()
        refreshNodeInfo()
    }

   
    private func walletURL(_ walletName: String) -> URL? {
        URL(string: "http://\(nodeAddress):\(rpcPort)/wallet/\(walletName)")
    }
    func sendWalletRPC(method: String, params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        guard let wallet = selectedWallet else {
            completion(.failure(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "No wallet selected."])))
            return
        }
        sendWalletRPCFor(walletName: wallet.name, method: method, params: params, completion: completion)
    }
    func sendWalletRPCFor(walletName: String, method: String, params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = walletURL(walletName) else {
            completion(.failure(NSError(domain:"", code: 0, userInfo: [NSLocalizedDescriptionKey:"Invalid wallet RPC URL."])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = "\(rpcUser):\(rpcPassword)"
        guard let credData = credentials.data(using: .utf8) else {
            completion(.failure(NSError(domain:"", code: 0, userInfo: [NSLocalizedDescriptionKey:"Error encoding credentials."])))
            return
        }
        request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["jsonrpc": "1.0", "id": "swift-ui", "method": method, "params": params]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let finish: (Result<Any, Error>) -> Void = { result in
                if Thread.isMainThread { completion(result) }
                else { DispatchQueue.main.async { completion(result) } }
            }
            if let error = error { finish(.failure(error)); return }
            guard let data = data else {
                finish(.failure(NSError(domain:"", code: 0, userInfo: [NSLocalizedDescriptionKey:"No data received."])))
                return
            }
            do { finish(.success(try JSONSerialization.jsonObject(with: data))) }
            catch { finish(.failure(error)) }
        }.resume()
    }

   
    func createNewWallet(name: String) {
        guard isConnected, let rpcService = rpcService else { return }
        
        rpcService.sendRPC(method: "createwallet", params: [name]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.listWalletsFromNode()
                if let index = self.wallets.firstIndex(where: { $0.name == name }) {
                    self.wallets[index].defaultAddressType = self.newWalletPreferredType
                }
                self.selectedWallet = self.wallets.first(where: { $0.name == name })
                self.rpcResponse = "Created new wallet: " + name
            case .failure(let error):
                self.rpcResponse = "Error creating wallet: " + error.localizedDescription
            }
        }
    }

    func sendBitcoin() {
        guard !recipientAddress.isEmpty, !amountBTC.isEmpty, isConnected else {
            self.transactionSendStatus = .failure(reason: "Recipient or amount is empty, or node not connected.")
            return
        }
        
        let trimmedAmount = amountBTC.trimmingCharacters(in: .whitespacesAndNewlines)
        var amountStr = trimmedAmount
        if let first = amountStr.first, first == "." { amountStr = "0" + amountStr }
        let amountNumber = NSDecimalNumber(string: amountStr)
        if amountNumber == NSDecimalNumber.notANumber {
            self.transactionSendStatus = .failure(reason: "Invalid amount."); return
        }
        let balanceNumber = NSDecimalNumber(string: walletBalance)
        if amountNumber.compare(balanceNumber) == .orderedDescending {
            self.transactionSendStatus = .failure(reason: "Insufficient Bitcoin balance.")
            self.errorMessage = "Insufficient Bitcoin balance."; self.showAlert = true; return
        }

        
        let feeRateBTCPerKB: Double = computeFeeRateBTCPerKB(option: feeOption, custom: customFeeRate)

        transactionSendStatus = .processing; isLoading = true
        sendWalletRPC(method: "settxfee", params: [feeRateBTCPerKB]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.sendWalletRPC(method: "sendtoaddress", params: [self.recipientAddress, amountNumber]) { result in
                    self.isLoading = false
                    switch result {
                    case .success(let json):
                        if let dict = json as? [String: Any], let txid = dict["result"] as? String {
                            self.transactionSendStatus = .success(txid: txid)
                            self.rpcResponse = "Sent BTC. Transaction ID: " + txid
                            let pendingTx = TransactionModel(txid: txid, amount: amountNumber.doubleValue, confirmations: 0, walletName: self.selectedWallet?.name ?? "Unknown")
                            self.transactions.insert(pendingTx, at: 0)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.transactionSendStatus = .idle }
                        } else {
                            let resp = String(describing: json)
                            self.transactionSendStatus = .failure(reason: "Unexpected response: " + resp)
                            self.rpcResponse = "Sent BTC. Response: " + resp
                            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.transactionSendStatus = .idle }
                        }
                    case .failure(let error):
                        self.transactionSendStatus = .failure(reason: error.localizedDescription)
                        self.rpcResponse = "Error sending BTC: " + error.localizedDescription
                        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.transactionSendStatus = .idle }
                    }
                }
            case .failure(let error):
                self.isLoading = false
                self.transactionSendStatus = .failure(reason: "Failed to set fee: " + error.localizedDescription)
                self.rpcResponse = "Failed to set fee: " + error.localizedDescription
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.transactionSendStatus = .idle }
            }
        }
    }

    
    func computeFeeRateBTCPerKB(option: FeeOption, custom: String) -> Double {
        if liveFeeActive {
            switch option {
            case .low:      return satPerVBToBtcPerKB(liveLowSatVb ?? 1.0)
            case .standard: return satPerVBToBtcPerKB(liveStdSatVb ?? max((liveLowSatVb ?? 1.0) * 1.8, 2))
            case .high:     return satPerVBToBtcPerKB(liveHighSatVb ?? max((liveStdSatVb ?? 2) * 1.25, 3))
            case .custom:   return Double(custom) ?? 0.0
            }
        } else {
            switch option {
            case .low:      return 0.00000500
            case .standard: return 0.00001400
            case .high:     return 0.00002000
            case .custom:   return Double(custom) ?? 0.0
            }
        }
    }

    func generateAddress(attempt: Int = 0) {
        if selectedWallet == nil {
            if let firstWallet = wallets.first { selectedWallet = firstWallet }
            else { self.rpcResponse = "No wallet available. Please create or load a wallet."; return }
        }
        guard let wallet = selectedWallet else { self.rpcResponse = "No wallet selected."; return }
        guard attempt < 3 else { self.rpcResponse = "Failed to generate a unique address after several attempts."; return }
        isLoading = true
        let type = selectedAddressType.isEmpty ? wallet.defaultAddressType : selectedAddressType
        sendWalletRPC(method: "getnewaddress", params: ["", type]) { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any] {
                    if let errorObj = dict["error"] as? [String: Any], let errMsg = errorObj["message"] as? String {
                        self.rpcResponse = "Error from node: " + errMsg; return
                    }
                    if let addr = dict["result"] as? String {
                        if wallet.addresses.contains(where: { $0.address == addr }) { self.generateAddress(attempt: attempt + 1) }
                        else {
                            wallet.usedAddresses.insert(addr)
                            let newAddress = WalletAddress(address: addr, label: nil, balance: 0.0, isUsed: false)
                            wallet.addresses.append(newAddress)
                            self.generatedAddress = addr
                            self.rpcResponse = "New address generated: " + addr
                        }
                    } else { self.rpcResponse = "Unexpected response when generating address: " + String(describing: json) }
                } else { self.rpcResponse = "Unexpected response format when generating address." }
            case .failure(let error):
                self.rpcResponse = "Error generating address: " + error.localizedDescription
            }
        }
    }

    func fetchTransactions() {
        isLoading = true
        sendWalletRPC(method: "listtransactions", params: ["*", 1000]) { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let txArray = dict["result"] as? [[String: Any]] {
                    self.transactions = Array(txArray.compactMap { tx in
                        guard let txid = tx["txid"] as? String,
                              let amount = tx["amount"] as? Double,
                              let confirmations = tx["confirmations"] as? Int else { return nil }
                        return TransactionModel(txid: txid, amount: amount, confirmations: confirmations, walletName: self.selectedWallet?.name ?? "Unknown")
                    }.reversed())
                    self.rpcResponse = "Transaction history updated."
                }
            case .failure(let error):
                self.rpcResponse = "Error fetching transactions: " + error.localizedDescription
            }
        }
    }

    func executeRPC() {
        guard !rpcCommand.isEmpty else { return }
        isLoading = true
        rpcService?.sendRPC(method: rpcCommand, params: []) { [weak self] result in
            guard let self = self else { return }
            self.isLoading = false
            switch result {
            case .success(let json):
                let resp = String(describing: json)
                self.rpcResponse = "Response: " + resp
            case .failure(let error):
                self.rpcResponse = "Error executing command: " + error.localizedDescription
            }
        }
    }

    func listWalletsFromNode() {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "listwalletdir", params: []) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any],
                   let resultDict = dict["result"] as? [String: Any],
                   let walletsArray = resultDict["wallets"] as? [[String: Any]] {
                    let discovered = walletsArray.compactMap { $0["name"] as? String }
                    let merged: [WalletModel] = discovered.map { name in
                        if let existing = self.wallets.first(where: { $0.name == name }) { return existing }
                        return WalletModel(name: name)
                    }
                    self.wallets = merged
                    if self.selectedWallet == nil, let first = self.wallets.first { self.selectedWallet = first }
                    self.fetchBalancesForWalletList()
                }
            case .failure(let error):
                print("Error listing wallets: " + error.localizedDescription)
            }
        }
    }

    func selectWallet(wallet: WalletModel) {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "loadwallet", params: [wallet.name]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.selectedWallet = wallet
                self.rpcResponse = "Loaded wallet: " + wallet.name
                self.updateBalanceForWallet(wallet.name)
            case .failure(let error):
                self.selectedWallet = wallet
                self.rpcResponse = "Loaded wallet (or already loaded): " + wallet.name + " — " + error.localizedDescription
                self.updateBalanceForWallet(wallet.name)
            }
        }
    }

    func addNodeToHistory(node: String) {
        if !nodeHistory.contains(node) {
            nodeHistory.append(node)
            UserDefaults.standard.set(nodeHistory, forKey: "NodeHistory")
        }
    }
    func purgeNodeHistory() {
        nodeHistory = []
        UserDefaults.standard.removeObject(forKey: "NodeHistory")
    }

    // MARK: - Wallet list balances
    func fetchBalancesForWalletList() {
        guard isConnected, let rpc = rpcService else { return }
        rpc.sendRPC(method: "listwallets", params: []) { [weak self] res in
            guard let self = self else { return }
            var loaded: Set<String> = []
            if case .success(let obj) = res {
                if let dict = obj as? [String: Any], let arr = dict["result"] as? [String] {
                    loaded = Set(arr)
                } else if let arr = obj as? [String] {
                    loaded = Set(arr)
                }
            }
            for wallet in self.wallets {
                let name = wallet.name
                func getBalance() {
                    self.sendWalletRPCFor(walletName: name, method: "getbalance", params: []) { result in
                        if case .success(let j) = result,
                           let d = j as? [String: Any],
                           let bal = d["result"] as? Double {
                            DispatchQueue.main.async {
                                wallet.balanceBTC = bal
                            }
                        }
                    }
                }
                if loaded.contains(name) { getBalance() }
                else {
                    rpc.sendRPC(method: "loadwallet", params: [name]) { _ in getBalance() }
                }
            }
        }
    }

    func updateBalanceForWallet(_ name: String) {
        sendWalletRPCFor(walletName: name, method: "getbalance", params: []) { [weak self] res in
            guard let self = self else { return }
            if case .success(let j) = res,
               let d = j as? [String: Any],
               let bal = d["result"] as? Double,
               let idx = self.wallets.firstIndex(where: { $0.name == name }) {
                DispatchQueue.main.async {
                    self.wallets[idx].balanceBTC = bal
                }
            }
        }
    }

    
    func fetchAddressesBalances() {
        guard let wallet = selectedWallet else { return }
        sendWalletRPC(method: "listunspent", params: [0, 9999999, []]) { result in
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let utxos = dict["result"] as? [[String: Any]] {
                    var balances: [String: Double] = [:]
                    for utxo in utxos {
                        if let address = utxo["address"] as? String, let amount = utxo["amount"] as? Double {
                            balances[address, default: 0.0] += amount
                        }
                    }
                    for i in 0..<wallet.addresses.count {
                        let addr = wallet.addresses[i].address
                        wallet.addresses[i].balance = balances[addr] ?? 0.0
                    }
                }
            case .failure(let error):
                print("Error fetching address balances: \(error.localizedDescription)")
            }
        }
    }

    func fetchAllWalletAddresses() {
        guard let _ = selectedWallet else { return }
        sendWalletRPC(method: "listlabels", params: []) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let labels = dict["result"] as? [String], !labels.isEmpty {
                    var all: [WalletAddress] = []
                    let group = DispatchGroup()
                    for label in labels {
                        group.enter()
                        self.sendWalletRPC(method: "getaddressesbylabel", params: [label]) { result in
                            if case .success(let json2) = result,
                               let d2 = json2 as? [String: Any],
                               let addressesDict = d2["result"] as? [String: Any] {
                                for (address, detailsAny) in addressesDict {
                                    if let details = detailsAny as? [String: Any] {
                                        let balance = details["balance"] as? Double ?? 0.0
                                        let lbl = details["label"] as? String
                                        let isUsed = balance > 0.0
                                        all.append(WalletAddress(address: address, label: lbl, balance: balance, isUsed: isUsed))
                                    }
                                }
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) { self.selectedWallet?.addresses = all }
                } else {
                    self.sendWalletRPC(method: "getaddressesbylabel", params: [""]) { result in
                        if case .success(let json2) = result,
                           let d2 = json2 as? [String: Any],
                           let addressesDict = d2["result"] as? [String: Any] {
                            var all: [WalletAddress] = []
                            for (address, detailsAny) in addressesDict {
                                if let details = detailsAny as? [String: Any] {
                                    let balance = details["balance"] as? Double ?? 0.0
                                    let lbl = details["label"] as? String
                                    let isUsed = balance > 0.0
                                    all.append(WalletAddress(address: address, label: lbl, balance: balance, isUsed: isUsed))
                                }
                            }
                            self.selectedWallet?.addresses = all
                        }
                    }
                }
            case .failure(let error):
                print("Error fetching labels: \(error.localizedDescription)")
            }
        }
    }

    
    @Published var sweepStatus: String = ""

    
    private func fallbackSweepSendToAddress(fromWallet walletName: String, toAddress dest: String, completion: @escaping (String) -> Void) {
        sendWalletRPCFor(walletName: walletName, method: "getbalance", params: []) { [weak self] balRes in
            guard let self = self else { return }
            switch balRes {
            case .success(let bj):
                var balance: Double = 0.0
                if let dict = bj as? [String: Any], let b = dict["result"] as? Double { balance = b }
                if balance <= 0.0 { completion("[\(walletName)] No funds to sweep."); return }
                self.sendWalletRPCFor(walletName: walletName, method: "sendtoaddress", params: [dest, balance, "", "", true]) { sendRes in
                    switch sendRes {
                    case .success(let sj):
                        if let d = sj as? [String: Any], let txid = d["result"] as? String {
                            completion("[\(walletName)] Swept via sendtoaddress. TXID: \(txid)")
                        } else {
                            completion("[\(walletName)] Sweep fallback failed (unexpected response).")
                        }
                    case .failure(let e):
                        completion("[\(walletName)] Sweep fallback failed: \(e.localizedDescription)")
                    }
                }
            case .failure(let e):
                completion("[\(walletName)] Could not read balance: \(e.localizedDescription)")
            }
        }
    }

    
    func sweepAll(toWalletName destWalletName: String) {
        guard isConnected, let rpc = rpcService else { sweepStatus = "Not connected."; return }
        let allNames = wallets.map { $0.name }
        let sources = allNames.filter { $0 != destWalletName }
        guard !sources.isEmpty else { sweepStatus = "No source wallets to sweep."; return }

      
        let sweepFeeRateBTCPerKB = computeFeeRateBTCPerKB(option: sweepFeeOption, custom: sweepCustomFeeRate)

       
        sendWalletRPCFor(walletName: destWalletName, method: "getnewaddress", params: ["", "bech32"]) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let j):
                guard let d = j as? [String: Any], let dest = d["result"] as? String else {
                    self.sweepStatus = "Could not obtain destination address."; return
                }

                
                rpc.sendRPC(method: "loadwallet", params: [destWalletName]) { _ in }

                let group = DispatchGroup()
                var lines: [String] = []

                func appendLine(_ s: String) {
                    DispatchQueue.main.async { lines.append(s) }
                }

                for src in sources {
                    group.enter()
                   
                    rpc.sendRPC(method: "loadwallet", params: [src]) { _ in
                        
                        self.sendWalletRPCFor(walletName: src, method: "settxfee", params: [sweepFeeRateBTCPerKB]) { _ in
                           
                            self.sendWalletRPCFor(walletName: src, method: "sendall", params: [[dest]]) { res in
                                switch res {
                                case .success(let js):
                                    if let dd = js as? [String: Any], let txid = dd["result"] as? String {
                                        appendLine("[\(src)] Swept via sendall. TXID: \(txid)")
                                        group.leave()
                                    } else {
                                        
                                        self.fallbackSweepSendToAddress(fromWallet: src, toAddress: dest) { msg in
                                            appendLine(msg); group.leave()
                                        }
                                    }
                                case .failure:
                                    self.fallbackSweepSendToAddress(fromWallet: src, toAddress: dest) { msg in
                                        appendLine(msg); group.leave()
                                    }
                                }
                            }
                        }
                    }
                }

                group.notify(queue: .main) {
                    self.sweepStatus = """
                    Sweep complete → Destination: \(destWalletName)
                    \(lines.joined(separator: "\n"))
                    """.trimmingCharacters(in: .whitespacesAndNewlines)
                }

            case .failure(let e):
                self.sweepStatus = "Failed to get destination address: \(e.localizedDescription)"
            }
        }
    }
}


extension BitcoinNodeViewModel {
    func defaultConfTarget(for option: FeeOption) -> Int {
        switch option {
        case .low:      return 18
        case .standard: return 6
        case .high:     return 2
        case .custom:   return 6
        }
    }
    func feeDescription(for option: FeeOption, custom: String) -> String {
        let rateBTCkb = computeFeeRateBTCPerKB(option: option, custom: custom)
        let satvb = btcPerKBToSatPerVB(rateBTCkb)
        let satvbStr: String = String(format: "%.1f", satvb)
        let blocks = defaultConfTarget(for: option)
        let mins = blocks * 10
        let badge = liveFeeActive ? " [live]" : ""
        return "\(satvbStr) sat/vB • ~\(blocks) blocks (~\(mins) min)\(badge)"
    }

    func feeRateBTCPerKB(for option: FeeOption) -> Double { computeFeeRateBTCPerKB(option: option, custom: customFeeRate) }
    func feeDescription(for option: FeeOption) -> String { feeDescription(for: option, custom: customFeeRate) }
    func lastFeeUpdateString() -> String {
        guard let t = liveFeeUpdatedAt else { return "never" }
        let fmt = DateFormatter(); fmt.dateStyle = .none; fmt.timeStyle = .short
        return fmt.string(from: t)
    }
}


struct FeeHelpView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Low"); Spacer(); Text(viewModel.feeDescription(for: .low)).monospacedDigit().foregroundColor(.secondary) }
            HStack { Text("Standard"); Spacer(); Text(viewModel.feeDescription(for: .standard)).monospacedDigit().foregroundColor(.secondary) }
            HStack { Text("High"); Spacer(); Text(viewModel.feeDescription(for: .high)).monospacedDigit().foregroundColor(.secondary) }
            if viewModel.feeOption == .custom {
                Divider().padding(.vertical, 2)
                HStack { Text("Custom"); Spacer(); Text(viewModel.feeDescription(for: .custom)).monospacedDigit().foregroundColor(.secondary) }
            }
            Text("Updated \(viewModel.lastFeeUpdateString())").font(.caption2).foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(8)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
        .accessibilityLabel("Fee level explanations showing sat per vbyte and estimated confirmation time")
    }
}


struct TransactionRowView: View {
    let transaction: TransactionModel
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HighlightableText(text: "TXID: \(transaction.txid)").font(.subheadline).lineLimit(1)
                Text("Confirmations: \(transaction.confirmations > 10 ? "10+" : "\(transaction.confirmations)")")
                    .font(.caption).foregroundColor(.gray)
            }
            Spacer()
            Text("\(transaction.amount, specifier: "%.8f") BTC")
                .foregroundColor(transaction.amount < 0 ? .red : .green)
        }
        .padding(5)
    }
}


struct TransactionDetailView: View {
    let transaction: TransactionModel
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var transactionDetails: [String: Any] = [:]
    @State private var loading: Bool = true
    @State private var error: String?
    @Environment(\.presentationMode) var presentationMode
    private var shortTxID: String { String(transaction.txid.prefix(8)) }
    var body: some View {
        NavigationView {
            Group {
                if loading { ProgressView("Loading Transaction Details...") }
                else if let error = error { Text("Error: " + error) }
                else { ScrollView { TransactionDetailsView(details: transactionDetails) } }
            }
            .navigationTitle("TX " + shortTxID + "...")
            .navigationBarItems(trailing: Button("Done") { presentationMode.wrappedValue.dismiss() })
            .onAppear { fetchDetails() }
        }
    }
    func fetchDetails() {
        viewModel.sendWalletRPC(method: "gettransaction", params: [transaction.txid]) { result in
            loading = false
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any] {
                    if let resultObj = dict["result"] {
                        if let resultDict = resultObj as? [String: Any] { transactionDetails = resultDict }
                        else { transactionDetails = ["result": resultObj] }
                    } else if let errorObj = dict["error"] as? [String: Any], let errMsg = errorObj["message"] as? String {
                        error = errMsg
                    } else { error = "Unexpected response format" }
                } else { error = "Unexpected response format" }
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}

struct BlockDetailView: View {
    let blockHash: String
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var blockDetails: [String: Any] = [:]
    @State private var blockStats: [String: Any] = [:]
    @Environment(\.presentationMode) var presentationMode
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Block Information")) {
                    if let height = blockDetails["height"] as? Int { HStack { Text("Block"); Spacer(); Text("\(height)") } }
                    if let hash = blockDetails["hash"] as? String {
                        let displayHash = String(hash.prefix(2)) + ".." + String(hash.suffix(6))
                        HStack { Text("Hash"); Spacer(); Text(displayHash) }
                    }
                    if let timeInt = blockDetails["time"] as? Int {
                        let date = Date(timeIntervalSince1970: TimeInterval(timeInt))
                        HStack { Text("Timestamp"); Spacer(); Text(dateFormatted(date: date)) }
                        HStack { Text("Relative Time"); Spacer(); Text(relativeTime(from: date)) }
                    }
                    if let size = blockDetails["size"] as? Int { HStack { Text("Size"); Spacer(); Text(String(format: "%.2f MB", Double(size) / 1_000_000.0)) } }
                    if let weight = blockDetails["weight"] as? Int { HStack { Text("Weight"); Spacer(); Text(String(format: "%.2f MWU", Double(weight) / 1_000_000.0)) } }
                    if let nTx = blockDetails["nTx"] as? Int { HStack { Text("Transactions"); Spacer(); Text("\(nTx)") } }
                }
                if !blockStats.isEmpty {
                    Section(header: Text("Fee Statistics")) {
                        if let feerange = blockStats["feerange"] as? [Double], feerange.count >= 2 {
                            HStack { Text("Fee Span"); Spacer(); Text("\(Int(feerange[0])) - \(Int(feerange[1])) sat/vB") }
                        }
                        if let totalfee = blockStats["totalfee"] as? Double {
                            HStack { Text("Total Fees"); Spacer(); Text(String(format: "%.8f BTC", totalfee / 100_000_000.0)) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Block Detail")
            .navigationBarItems(trailing: Button("Done") { presentationMode.wrappedValue.dismiss() })
            .onAppear { fetchBlockData() }
        }
    }
    func fetchBlockData() {
        viewModel.rpcService?.sendRPC(method: "getblock", params: [blockHash, 2]) { result in
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let resultDict = dict["result"] as? [String: Any] { self.blockDetails = resultDict }
            case .failure(let error):
                self.blockDetails = ["error": error.localizedDescription]
            }
            fetchBlockStats()
        }
    }
    func fetchBlockStats() {
        viewModel.rpcService?.sendRPC(method: "getblockstats", params: [blockHash]) { result in
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any], let resultDict = dict["result"] as? [String: Any] { self.blockStats = resultDict }
            case .failure(let error):
                self.blockStats = ["error": error.localizedDescription]
            }
        }
    }
    func dateFormatted(date: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: date) }
    func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        else if interval < 3600 { let m = Int(interval / 60); return "\(m) minute\(m == 1 ? "" : "s") ago" }
        else if interval < 86400 { let h = Int(interval / 3600); return "\(h) hour\(h == 1 ? "" : "s") ago" }
        else if interval < 604800 { let d = Int(interval / 86400); return "\(d) day\(d == 1 ? "" : "s") ago" }
        else { let mo = Int(interval / 2419200); return "\(mo) month\(mo == 1 ? "" : "s") ago" }
    }
}


struct DashboardView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var selectedBlock: BlockInfo? = nil
    @State private var selectedMempoolEntry: MempoolEntry? = nil
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let currentHeight = Int(viewModel.blockHeight) {
                        Text("Next Block Height: \(currentHeight + 1)").font(.headline)
                    }
                    VStack(spacing: 10) {
                        HStack {
                            if let candidate = viewModel.nextBlockCandidate {
                                VStack {
                                    Text("Next Block").font(.caption)
                                    Text("Mempool: \(candidate.mempoolTxCount) txs").font(.headline)
                                }
                                .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(8)
                            }
                            Spacer()
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(viewModel.recentBlocks) { block in
                                        VStack {
                                            Text("H: \(block.height)").font(.caption)
                                            let shortHash = String(block.hash.prefix(2)) + ".." + String(block.hash.suffix(6))
                                            Text(shortHash).font(.caption2)
                                            Text(Date(timeIntervalSince1970: TimeInterval(block.time)), style: .time).font(.caption2)
                                        }
                                        .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(8)
                                        .onTapGesture { selectedBlock = block }
                                        .transition(.move(edge: .leading))
                                    }
                                }
                                .animation(.easeInOut(duration: 0.5), value: viewModel.recentBlocks)
                            }
                        }
                    }
                    .padding().background(Color(UIColor.systemGroupedBackground)).cornerRadius(8)

                    HStack {
                        Text("Wallet: \(viewModel.selectedWallet?.name ?? "None")").font(.subheadline)
                        Spacer()
                        if viewModel.privacyMode { Text("Balance: Hidden").font(.subheadline) }
                        else {
                            let balanceToDisplay = (Double(viewModel.walletBalance) != nil) ? String(format: "%.8f", Double(viewModel.walletBalance)!) : "0"
                            Text("Balance: \(balanceToDisplay) BTC").font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity).padding().background(Color(UIColor.systemBackground)).cornerRadius(8).padding(.horizontal)

                    VStack(spacing: 5) {
                        Text("Bitcoin Node Status").font(.title).bold()
                        HStack {
                            Circle().fill(viewModel.isConnected ? Color.green : Color.red).frame(width: 10, height: 10)
                            Text(viewModel.isConnected ? "Connected" : "Not Connected").foregroundColor(viewModel.isConnected ? .green : .red)
                        }
                    }

                    if viewModel.isConnected {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Block Height: \(viewModel.blockHeight)")
                            Text("Mempool Size: \(viewModel.mempoolSize)")
                            Text("Peers Connected: \(viewModel.peersConnected)")
                            Text("Sync Status: \(viewModel.syncStatus)")
                        }
                        .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(8)

                        Text("Next Block Preview").font(.headline).padding(.top)
                        AnimatedNextBlockView(mempoolEntries: viewModel.mempoolEntries, onSelect: { entry in
                            selectedMempoolEntry = entry
                        }).padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .sheet(item: $selectedBlock) { block in BlockDetailView(blockHash: block.hash, viewModel: viewModel) }
            .sheet(item: $selectedMempoolEntry) { entry in MempoolTxDetailView(txid: entry.txid, viewModel: viewModel) }
        }
        .navigationViewStyle(.stack)
    }
}


struct MempoolTxDetailView: View {
    let txid: String
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var transactionDetails: [String: Any] = [:]
    @State private var loading: Bool = true
    @State private var error: String?
    @Environment(\.presentationMode) var presentationMode
    private var shortTxID: String { String(txid.prefix(8)) }
    var body: some View {
        NavigationView {
            Group {
                if loading { ProgressView("Loading Transaction Details...") }
                else if let error = error { Text("Error: " + error) }
                else { ScrollView { TransactionDetailsView(details: transactionDetails) } }
            }
            .navigationTitle("Mempool TX " + shortTxID + "...")
            .navigationBarItems(trailing: Button("Done") { presentationMode.wrappedValue.dismiss() })
            .onAppear { fetchDetails() }
        }
    }
    func fetchDetails() {
        viewModel.rpcService?.sendRPC(method: "getrawtransaction", params: [txid, true]) { result in
            loading = false
            switch result {
            case .success(let json):
                if let dict = json as? [String: Any] {
                    if let resultObj = dict["result"] {
                        if let resultDict = resultObj as? [String: Any] { transactionDetails = resultDict }
                        else { transactionDetails = ["result": resultObj] }
                    } else if let errorObj = dict["error"] as? [String: Any], let errMsg = errorObj["message"] as? String {
                        error = errMsg
                    } else { error = "Unexpected response format" }
                } else { error = "Unexpected response format" }
            case .failure(let err): error = err.localizedDescription
            }
        }
    }
}


struct NewWalletSheetView: View {
    @Binding var walletName: String
    @Binding var preferredType: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    private let types: [(title: String, tag: String)] = [
        ("Legacy (P2PKH)", "legacy"),
        ("P2SH-SegWit", "p2sh-segwit"),
        ("Bech32 (native SegWit)", "bech32"),
        ("Bech32m (Taproot)", "bech32m")
    ]
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Wallet Name")) {
                    TextField("e.g. mywallet", text: $walletName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Default Address Type")) {
                    Picker("Type", selection: $preferredType) {
                        ForEach(types, id: \.tag) { t in
                            Text(t.title).tag(t.tag)
                        }
                    }
                }
            }
            .navigationTitle("New Wallet")
            .navigationBarItems(
                leading: Button("Cancel", action: onCancel),
                trailing: Button("Create", action: onCreate).disabled(walletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            )
        }
    }
}


struct WalletRowView: View {
    @ObservedObject var wallet: WalletModel
    let isSelected: Bool
    let onLoad: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(wallet.name)
                if let b = wallet.balanceBTC {
                    Text(String(format: "%.8f BTC", b)).font(.caption).foregroundColor(.secondary).monospacedDigit()
                } else {
                    Text("—").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else {
                Button("Load", action: onLoad).foregroundColor(.blue)
            }
        }
        .padding(5)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
}


struct WalletView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var showNewWalletSheet = false
    @State private var newWalletName: String = ""
    @State private var selectedTransaction: TransactionModel? = nil
    @State private var showSendConfirmation: Bool = false

    
    @State private var destinationWalletName: String = ""
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 20) {
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Wallet Management").font(.headline)
                        if viewModel.wallets.isEmpty {
                            Text("No wallets discovered on the node.").foregroundColor(.gray)
                        } else {
                            ForEach(viewModel.wallets, id: \.id) { wallet in
                                WalletRowView(
                                    wallet: wallet,
                                    isSelected: viewModel.selectedWallet == wallet,
                                    onLoad: { viewModel.selectWallet(wallet: wallet) }
                                )
                            }
                        }
                        HStack {
                            Button(action: { viewModel.fetchBalancesForWalletList() }) {
                                Label("Refresh Balances", systemImage: "arrow.clockwise")
                            }
                            Spacer()
                            Button(action: { showNewWalletSheet = true }) {
                                Text("Create New Wallet")
                                    .padding(8)
                                    .background(Color.purple)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding().background(Color(UIColor.systemGroupedBackground)).cornerRadius(8)

                  
                    HStack {
                        Text("Current Wallet: \(viewModel.selectedWallet?.name ?? "None")").font(.subheadline)
                        Spacer()
                        if viewModel.privacyMode { Text("Balance: Hidden").font(.subheadline) }
                        else {
                            let balanceToDisplay = (Double(viewModel.walletBalance) != nil) ? String(format: "%.8f", Double(viewModel.walletBalance)!) : "0"
                            Text("Balance: \(balanceToDisplay) BTC").font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity).padding().background(Color(UIColor.systemBackground)).cornerRadius(8).padding(.horizontal)

                    
                    if viewModel.selectedWallet != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Network Fee")
                                Spacer()
                                Button {
                                    viewModel.refreshDynamicFees()
                                } label: {
                                    Label("Refresh fees", systemImage: "arrow.clockwise")
                                }
                                .disabled(!viewModel.isConnected)
                            }
                            Text("Select Fee Option (Send)").font(.subheadline)
                            Picker("Fee Option", selection: $viewModel.feeOption) {
                                ForEach(BitcoinNodeViewModel.FeeOption.allCases) { option in Text(option.rawValue).tag(option) }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            if viewModel.feeOption == .custom {
                                TextField("Custom Fee Rate (BTC/kB)", text: $viewModel.customFeeRate)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                            FeeHelpView(viewModel: viewModel)
                        }
                        .padding(.horizontal)
                    }

                   
                    if viewModel.selectedWallet != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Send Bitcoin").bold()
                            TextField("Recipient Address", text: $viewModel.recipientAddress).textFieldStyle(RoundedBorderTextFieldStyle())
                            TextField("Amount (BTC)", text: $viewModel.amountBTC).textFieldStyle(RoundedBorderTextFieldStyle())
                            Button(action: { showSendConfirmation = true }) {
                                Text("Send BTC").frame(maxWidth: .infinity).padding().background(Color.red).foregroundColor(.white).cornerRadius(8)
                            }
                            Group {
                                switch viewModel.transactionSendStatus {
                                case .idle: EmptyView()
                                case .processing: ProgressView("Sending...")
                                case .success(let txid):
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                        Text("Transaction sent: \(txid)")
                                        Button(action: { UIPasteboard.general.string = txid }) { Image(systemName: "doc.on.doc") }
                                    }
                                case .failure(let reason):
                                    Text("Error: \(reason)").foregroundColor(.red)
                                }
                            }.padding(.top, 5)

                            VStack(spacing: 10) {
                                Text("Receive Bitcoin").bold()

                                
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Receive Address Format").font(.subheadline)
                                    Picker("Address Format", selection: $viewModel.selectedAddressType) {
                                        Text("Legacy").tag("legacy")
                                        Text("P2SH-SegWit").tag("p2sh-segwit")
                                        Text("Bech32").tag("bech32")
                                        Text("Bech32m").tag("bech32m")
                                    }
                                    .pickerStyle(SegmentedPickerStyle())
                                }

                                Button(action: { viewModel.generateAddress() }) {
                                    Text("Generate New Address").frame(maxWidth: .infinity).padding().background(Color.green).foregroundColor(.white).cornerRadius(8)
                                }
                                HStack {
                                    Text(viewModel.generatedAddress).foregroundColor(.gray).lineLimit(1)
                                    Button(action: { UIPasteboard.general.string = viewModel.generatedAddress }) { Image(systemName: "doc.on.doc").foregroundColor(.blue) }
                                }
                            }
                        }
                        .padding().background(Color(UIColor.secondarySystemBackground)).cornerRadius(8)
                    } else {
                        Text("Please create and load a wallet to access wallet functions.").foregroundColor(.gray)
                    }

                   
                    if !viewModel.wallets.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Sweep All Wallets").font(.headline)
                            Text("This will move ALL spendable BTC from every wallet on this node into the destination wallet below. The destination wallet is excluded from sweeping, and a fresh address will be generated for receiving.")
                                .font(.footnote)
                                .foregroundColor(.secondary)

                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text("Destination Wallet").font(.caption)
                                    Picker("Destination Wallet", selection: $destinationWalletName) {
                                        Text("Select…").tag("")
                                        ForEach(viewModel.wallets, id: \.id) { w in
                                            Text(w.name).tag(w.name)
                                        }
                                    }
                                    .pickerStyle(MenuPickerStyle())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                VStack(alignment: .leading) {
                                    Text("Sweep Speed").font(.caption)
                                    Picker("Sweep Speed", selection: $viewModel.sweepFeeOption) {
                                        ForEach(BitcoinNodeViewModel.FeeOption.allCases) { opt in
                                            Text(opt.rawValue).tag(opt)
                                        }
                                    }
                                    .pickerStyle(MenuPickerStyle())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            if viewModel.sweepFeeOption == .custom {
                                TextField("Custom Sweep Fee (BTC/kB)", text: $viewModel.sweepCustomFeeRate)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }

                            
                            Text("Selected sweep fee: \(viewModel.feeDescription(for: viewModel.sweepFeeOption, custom: viewModel.sweepCustomFeeRate))")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Spacer()
                                Button {
                                    guard !destinationWalletName.isEmpty else {
                                        viewModel.sweepStatus = "Choose a destination wallet."; return
                                    }
                                    viewModel.sweepAll(toWalletName: destinationWalletName)
                                } label: {
                                    Text("Sweep All Wallets Now").padding().frame(maxWidth: .infinity)
                                }
                                .background(Color.orange).foregroundColor(.white).cornerRadius(8)
                                Spacer()
                            }

                            if !viewModel.sweepStatus.isEmpty {
                                Text(viewModel.sweepStatus).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.leading)
                            }
                        }
                        .padding().background(Color(UIColor.systemGroupedBackground)).cornerRadius(8)
                    }

                   
                    if viewModel.selectedWallet != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Wallet Transactions (Wallet: \(viewModel.selectedWallet?.name ?? "Unknown"))").font(.headline)
                            ForEach(viewModel.transactions, id: \.id) { tx in
                                Button(action: { selectedTransaction = tx }) { TransactionRowView(transaction: tx) }
                            }
                        }
                        .padding().background(Color(UIColor.systemGroupedBackground)).cornerRadius(8)
                    }
                }
                .padding()
            }
            .navigationTitle("Wallet")
            .sheet(isPresented: $showNewWalletSheet) {
                NewWalletSheetView(walletName: $newWalletName, preferredType: $viewModel.newWalletPreferredType, onCreate: {
                    viewModel.createNewWallet(name: newWalletName)
                    newWalletName = ""; showNewWalletSheet = false
                }, onCancel: {
                    newWalletName = ""; showNewWalletSheet = false
                })
            }
            .sheet(item: $selectedTransaction) { tx in TransactionDetailView(transaction: tx, viewModel: viewModel) }
            .alert(isPresented: $showSendConfirmation) {
                Alert(title: Text("Confirm Transaction"),
                      message: Text("Are you sure you want to send \(viewModel.amountBTC) BTC to \(viewModel.recipientAddress)?"),
                      primaryButton: .destructive(Text("Send")) { viewModel.sendBitcoin() },
                      secondaryButton: .cancel())
            }
            .onAppear {
                if viewModel.isConnected {
                    viewModel.refreshDynamicFees()
                    viewModel.startFeePolling()
                    viewModel.fetchBalancesForWalletList()  // ensure balances show on open
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}


struct TerminalView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var selectedSegment = 0
    let segments = ["Terminal", "Help"]
    let helpCommands: [String] = [
        "getblockchaininfo - Get blockchain info",
        "getnetworkinfo - Get network info",
        "getmempoolinfo - Get mempool info",
        "sendtoaddress <address> <amount> - Send bitcoin",
        "listtransactions - List transactions",
        "getbalance - Get wallet balance",
        "getnewaddress - Generate a new address",
        "help - Show help"
    ]
    var body: some View {
        NavigationView {
            VStack {
                Picker("", selection: $selectedSegment) {
                    ForEach(0..<segments.count, id: \.self) { index in Text(segments[index]).tag(index) }
                }
                .pickerStyle(SegmentedPickerStyle()).padding()
                if selectedSegment == 0 {
                    VStack(spacing: 10) {
                        TextField("Enter RPC Command", text: $viewModel.rpcCommand).textFieldStyle(RoundedBorderTextFieldStyle())
                        Button(action: { viewModel.executeRPC() }) {
                            Text("Execute").frame(maxWidth: .infinity).padding().background(Color.blue).foregroundColor(.white).cornerRadius(8)
                        }.padding(.horizontal)
                        Divider().padding(.horizontal)
                        ScrollView {
                            Text(viewModel.rpcResponse)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.gray)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                        }.padding()
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(helpCommands, id: \.self) { cmd in
                                Text(cmd).font(.system(.body, design: .monospaced))
                                    .padding(5).background(Color(UIColor.secondarySystemBackground)).cornerRadius(5)
                            }
                        }.padding()
                    }
                }
                Spacer()
            }
            .navigationTitle("Terminal")
        }
        .navigationViewStyle(.stack)
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @AppStorage("isDarkMode") var isDarkMode: Bool = false
    @State private var showPurgeAlert = false
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Connection Settings")) {
                    TextField("Node IP Address", text: $viewModel.nodeAddress)
                    TextField("RPC Port", text: $viewModel.rpcPort)
                    TextField("RPC Username", text: $viewModel.rpcUser)
                    SecureField("RPC Password", text: $viewModel.rpcPassword)
                }
                Section(header: Text("Node Connection")) {
                    HStack {
                        Text("Status:")
                        Circle().fill(viewModel.isConnected ? Color.green : Color.red).frame(width: 10, height: 10)
                        Text(viewModel.isConnected ? "Connected" : "Not Connected")
                    }
                    if viewModel.isConnected {
                        Button("Disconnect") { viewModel.disconnectNode() }.foregroundColor(.red)
                    } else {
                        Button("Connect") { viewModel.connectToNode() }.foregroundColor(.blue)
                    }
                }
                Section(header: Text("Node History")) {
                    if viewModel.nodeHistory.isEmpty {
                        Text("No nodes in history.").foregroundColor(.gray)
                    } else {
                        ForEach(viewModel.nodeHistory, id: \.self) { node in
                            HStack {
                                Text(node)
                                Spacer()
                                Button("Reconnect") {
                                    viewModel.nodeAddress = node
                                    if let port = UserDefaults.standard.string(forKey: "CurrentNodePort") {
                                        viewModel.rpcPort = port
                                    }
                                    viewModel.connectToNode()
                                }
                            }
                        }
                        Button("Purge History") { viewModel.purgeNodeHistory() }.foregroundColor(.red)
                    }
                }
                Section(header: Text("Preferences")) {
                    Toggle("Remember Me", isOn: $viewModel.rememberMe)
                    Toggle("Privacy Mode (Hide Balance)", isOn: $viewModel.privacyMode)
                }
                Section(header: Text("Appearance")) { Toggle("Dark Mode", isOn: $isDarkMode) }
                Section(header: Text("Reset")) {
                    Button("Purge Everything") { showPurgeAlert = true }.foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showPurgeAlert) {
                Alert(title: Text("Warning"),
                      message: Text("Are you sure? This will wipe all data from this device."),
                      primaryButton: .destructive(Text("Purge")) { viewModel.purgeAllData() },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(.stack)
    }
}


struct ContentView: View {
    @AppStorage("isDarkMode") private var isDarkMode: Bool = false
    @StateObject var viewModel = BitcoinNodeViewModel()
    var body: some View {
        TabView {
            DashboardView(viewModel: viewModel)
                .tabItem { Label("Dashboard", systemImage: "speedometer") }
            WalletView(viewModel: viewModel)
                .tabItem { Label("Wallet", systemImage: "wallet.pass") }
            TerminalView(viewModel: viewModel)
                .tabItem { Label("Terminal", systemImage: "terminal.fill") }
            SettingsView(viewModel: viewModel)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .alert(isPresented: $viewModel.showAlert) {
            Alert(title: Text("Error"),
                  message: Text(viewModel.errorMessage ?? "Unknown error"),
                  dismissButton: .default(Text("OK")))
        }
    }
}

struct ContentView_Previews: PreviewProvider { static var previews: some View { ContentView() } }
