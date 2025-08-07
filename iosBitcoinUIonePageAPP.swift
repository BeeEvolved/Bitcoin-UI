
import SwiftUI
import Combine
import Security
import Foundation

// HighlightableText View
struct HighlightableText: View {
    let text: String
    @State private var isHighlighted = false
    var body: some View {
        Text(text)
            .padding(4)
            .background(isHighlighted ? Color.yellow.opacity(0.4) : Color.clear)
            .cornerRadius(4)
            .onTapGesture {
                withAnimation {
                    isHighlighted.toggle()
                }
                UIPasteboard.general.string = text
            }
    }
}

// Keychain Helper
class KeychainHelper {
    static let shared = KeychainHelper()
  
    func save(_ service: String, account: String, data: Data) -> OSStatus {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ] as [String: Any]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil)
    }
  
    func read(_ service: String, account: String) -> Data? {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as [String: Any]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == noErr {
            return dataTypeRef as? Data
        }
        return nil
    }
  
    func delete(_ service: String, account: String) {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as [String: Any]
        SecItemDelete(query as CFDictionary)
    }
  
    func saveCredentials(username: String, password: String) {
        if let userData = username.data(using: .utf8),
           let passData = password.data(using: .utf8) {
            _ = save("BitcoinNodeRPC", account: "username", data: userData)
            _ = save("BitcoinNodeRPC", account: "password", data: passData)
        }
    }
  
    func loadCredentials() -> (username: String, password: String)? {
        guard let userData = read("BitcoinNodeRPC", account: "username"),
              let passData = read("BitcoinNodeRPC", account: "password"),
              let username = String(data: userData, encoding: .utf8),
              let password = String(data: passData, encoding: .utf8) else {
            return nil
        }
        return (username, password)
    }
  
    func clearCredentials() {
        delete("BitcoinNodeRPC", account: "username")
        delete("BitcoinNodeRPC", account: "password")
    }
}

// RPC Service
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
            completion(.failure(NSError(domain: "", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = "\(rpcUser):\(rpcPassword)"
        guard let credData = credentials.data(using: .utf8) else {
            completion(.failure(NSError(domain: "", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "Error encoding credentials"])))
            return
        }
        let base64Creds = credData.base64EncodedString()
        request.setValue("Basic \(base64Creds)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "jsonrpc": "1.0",
            "id": "swift-ui",
            "method": method,
            "params": params
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain:"", code: 0,
                                            userInfo: [NSLocalizedDescriptionKey:"No data received."])))
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                completion(.success(json))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}

// Explorer Models
struct BlockInfo: Identifiable, Equatable {
    var id: String { hash }
    let height: Int
    let hash: String
    let time: Int
}

struct BlockCandidate: Identifiable {
    var id: String { "next" }
    let mempoolTxCount: Int
    let estimatedFee: Double?
}

struct TransactionModel: Identifiable, Hashable {
    var id: String { txid }
    let txid: String
    let amount: Double
    let confirmations: Int
    let walletName: String
}

// Wallet Address Model
struct WalletAddress: Identifiable, Equatable {
    let id = UUID()
    let address: String
    var label: String?
    var balance: Double?
    var isUsed: Bool
}

// Wallet Model
class WalletModel: Identifiable, ObservableObject, Hashable {
    static func == (lhs: WalletModel, rhs: WalletModel) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    let id: UUID = UUID()
    @Published var name: String
    @Published var usedAddresses: Set<String> = []
    // This list will be refreshed dynamically from the node.
    @Published var addresses: [WalletAddress] = []
    init(name: String) {
        self.name = name
    }
}

// Mempool Entry Model
struct MempoolEntry: Identifiable, Equatable {
    var id: String { txid }
    let txid: String
    let fee: Double
    let size: Int
}

// Animated Next Block View - Enhanced with transitions and simplified animation
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
                // Large block container
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange, lineWidth: 3)
                    .frame(width: geo.size.width, height: geo.size.height)
               
                // Small transaction blocks animating in with transition
                ForEach(mempoolEntries) { entry in
                    if let position = packedPositions[entry.id] {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(colorForSize(size: txSize(for: entry)))
                            .frame(width: txSize(for: entry), height: txSize(for: entry))
                            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 2)
                            .position(CGPoint(x: position.x, y: position.y + (offsets[entry.id] ?? 0)))
                            .opacity(opacities[entry.id] ?? 1)
                            .transition(.opacity)
                            .onTapGesture {
                                onSelect(entry)
                            }
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
                offsets = [:]
                opacities = [:]
                packedPositions = [:]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    packedPositions = computePackedPositions(for: mempoolEntries, containerSize: CGSize(width: 300, height: 300))
                    animateEntries()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .onChange(of: mempoolEntries) {
            packedPositions = computePackedPositions(for: mempoolEntries, containerSize: CGSize(width: 300, height: 300))
            animateEntries()
        }
    }
  
    private func animateEntries() {
        for (index, entry) in mempoolEntries.enumerated() {
            offsets[entry.id] = -50 - CGFloat(index * 10)
            opacities[entry.id] = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.05) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    offsets[entry.id] = 0
                    opacities[entry.id] = 1
                }
            }
        }
    }
  
    private func computePackedPositions(for entries: [MempoolEntry], containerSize: CGSize) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        var rows: [[MempoolEntry]] = []
        var currentRow: [MempoolEntry] = []
        var currentWidth: CGFloat = 0
       
        for entry in entries {
            let s = txSize(for: entry)
            if currentWidth + s > containerSize.width {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = []
                currentWidth = 0
            }
            currentRow.append(entry)
            currentWidth += s
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
       
        var y: CGFloat = containerSize.height
        for row in rows.reversed() {  // Start filling from the bottom
            let maxH = row.map { txSize(for: $0) }.max() ?? 0
            var x: CGFloat = 0
            for entry in row {
                let s = txSize(for: entry)
                positions[entry.id] = CGPoint(x: x + s / 2, y: y - maxH / 2)
                x += s
            }
            y -= maxH
        }
       
        // If overflow (y < 0), we can handle it here, but for now, assume it fits
        return positions
    }
  
    private func colorForSize(size: CGFloat) -> Color {
        let saturation: Double
        switch size {
        case 10:
            saturation = 0.5
        case 25:
            saturation = 0.75
        default:
            saturation = 1.0
        }
        return Color(hue: 0.08, saturation: saturation, brightness: 1.0)
    }
  
    private func txSize(for entry: MempoolEntry) -> CGFloat {
        if entry.size < 200 {
            return 10 // small
        } else if entry.size < 500 {
            return 25 // medium
        } else {
            return 40 // large
        }
    }
}

// Transaction Details Recursive Views
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
                    if let key = key {
                        HighlightableText(text: "\(key):")
                            .font(.headline)
                    }
                    ForEach(dict.keys.sorted(), id: \.self) { subkey in
                        DetailView(key: subkey, value: dict[subkey]!)
                            .padding(.leading, 10)
                    }
                }
            } else if let array = value as? [Any] {
                VStack(alignment: .leading, spacing: 4) {
                    if let key = key {
                        HighlightableText(text: "\(key):")
                            .font(.headline)
                    }
                    ForEach(0..<array.count, id: \.self) { index in
                        DetailView(key: "Item \(index + 1)", value: array[index])
                            .padding(.leading, 10)
                    }
                }
            } else {
                if let key = key {
                    HighlightableText(text: "\(key): \(formattedValue(for: key, value: value))")
                } else {
                    HighlightableText(text: "\(formattedValue(for: "", value: value))")
                }
            }
        }
    }
}

func formattedValue(for key: String, value: Any) -> String {
    if key.lowercased().contains("time"), let timeInt = value as? Int {
        let date = Date(timeIntervalSince1970: TimeInterval(timeInt))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    } else {
        return String(describing: value)
    }
}

// Edit Address Label View
struct EditAddressLabelView: View {
    @ObservedObject var wallet: WalletModel
    var address: WalletAddress
    @Binding var newLabel: String
    @Environment(\.presentationMode) var presentationMode
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Edit Label for Address")) {
                    TextField("Label", text: $newLabel)
                }
            }
            .navigationTitle("Edit Label")
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }, trailing: Button("Save") {
                updateLabel()
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
  
    func updateLabel() {
        if let index = wallet.addresses.firstIndex(where: { $0.id == address.id }) {
            wallet.addresses[index].label = newLabel
        }
    }
}

// Bitcoin Node View Model
class BitcoinNodeViewModel: ObservableObject {
    // Connection and node details
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
  
    // Explorer properties
    @Published var recentBlocks: [BlockInfo] = []
    @Published var nextBlockCandidate: BlockCandidate? = nil
  
    // Wallet properties
    @Published var recipientAddress: String = ""
    @Published var amountBTC: String = ""
    @Published var generatedAddress: String = ""
    @Published var transactions: [TransactionModel] = []
  
    // RPC and terminal
    @Published var rpcResponse: String = "RPC response will appear here..."
    @Published var rpcCommand: String = "getblockchaininfo"
  
    // Loading and error states
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var showAlert: Bool = false
    @Published var rememberMe: Bool = false
    @Published var privacyMode: Bool = false
  
    // Wallet management
    @Published var wallets: [WalletModel] = []
    @Published var selectedWallet: WalletModel? = nil
  
    // Address format selection (wallet types)
    @Published var selectedAddressType: String = "legacy" // Options: "legacy", "p2sh-segwit", "bech32"
  
    // Node History
    @Published var nodeHistory: [String] = []
  
    // Mempool transactions and entries
    @Published var mempoolTransactions: [String] = []
    @Published var mempoolEntries: [MempoolEntry] = []
  
    var rpcService: RPCService? = nil
  
    // Polling timers - Adjusted intervals for efficiency (less glitchy, reduce network load)
    var blockPollingTimer: AnyCancellable?
    var mempoolPollingTimer: AnyCancellable?
    var transactionPollingTimer: AnyCancellable?
    var statusPollingTimer: AnyCancellable?
  
    // Transaction Send Status
    enum TransactionSendStatus {
        case idle
        case processing
        case success(txid: String)
        case failure(reason: String)
    }
    @Published var transactionSendStatus: TransactionSendStatus = .idle
  
    // Fee Option
    enum FeeOption: String, CaseIterable, Identifiable {
        var id: String { self.rawValue }
        case low = "Low"
        case standard = "Standard"
        case high = "High"
        case custom = "Custom"
    }
    @Published var feeOption: FeeOption = .standard
    @Published var customFeeRate: String = ""
  
    init() {
        if let currentNode = UserDefaults.standard.string(forKey: "CurrentNode") {
            self.nodeAddress = currentNode
            if let port = UserDefaults.standard.string(forKey: "CurrentNodePort") {
                self.rpcPort = port
            }
            if let credentials = KeychainHelper.shared.loadCredentials() {
                self.rpcUser = credentials.username
                self.rpcPassword = credentials.password
                self.rememberMe = true
                self.connectToNode()
            }
        }
        self.nodeHistory = UserDefaults.standard.stringArray(forKey: "NodeHistory") ?? []
    }
  
    func fetchMempoolTransactions() {
        rpcService?.sendRPC(method: "getrawmempool", params: [true]) { [weak self] result in // Use verbose to get fees directly
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let resultDict = dict["result"] as? [String: [String: Any]] {
                        var entries: [MempoolEntry] = []
                        for (txid, info) in resultDict {
                            var fee: Double? = nil
                            if let fees = info["fees"] as? [String: Any],
                               let baseFee = fees["base"] as? Double {
                                fee = baseFee
                            } else if let baseFee = info["fee"] as? Double {
                                fee = baseFee
                            }
                            if let fee = fee,
                               let size = info["vsize"] as? Int {
                                entries.append(MempoolEntry(txid: txid, fee: fee, size: size))
                            }
                        }
                        // Sort by fee rate descending for priority visualization
                        entries.sort { ($0.fee / Double($0.size)) > ($1.fee / Double($1.size)) }
                        self?.mempoolEntries = Array(entries.prefix(50)) // Limit to 50 for performance
                        self?.mempoolTransactions = self?.mempoolEntries.map { $0.txid } ?? []
                        self?.nextBlockCandidate = BlockCandidate(mempoolTxCount: resultDict.count, estimatedFee: nil)
                    }
                case .failure(let error):
                    print("Error fetching mempool transactions: \(error.localizedDescription)")
                    self?.errorMessage = error.localizedDescription
                    self?.showAlert = true
                }
            }
        }
    }
  
    func purgeAllData() {
        disconnectNode()
        wallets = []
        selectedWallet = nil
        transactions = []
        generatedAddress = ""
        recipientAddress = ""
        amountBTC = ""
        recentBlocks = []
        nextBlockCandidate = nil
        rpcResponse = ""
        rpcCommand = "getblockchaininfo"
        KeychainHelper.shared.clearCredentials()
        purgeNodeHistory()
    }
  
    func connectToNode() {
        self.rpcService = RPCService(nodeAddress: nodeAddress, rpcPort: rpcPort, rpcUser: rpcUser, rpcPassword: rpcPassword)
        isLoading = true
        rpcService?.sendRPC(method: "getblockchaininfo", params: []) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let json):
                    if let jsonDict = json as? [String: Any], jsonDict["result"] != nil {
                        self?.isConnected = true
                        self?.rpcResponse = "Successfully connected to your Bitcoin node!"
                        if self?.rememberMe ?? false {
                            KeychainHelper.shared.saveCredentials(username: self?.rpcUser ?? "", password: self?.rpcPassword ?? "")
                        }
                        UserDefaults.standard.set(self?.nodeAddress, forKey: "CurrentNode")
                        UserDefaults.standard.set(self?.rpcPort, forKey: "CurrentNodePort")
                        self?.refreshNodeInfo()
                        self?.fetchRecentBlocks()
                        self?.listWalletsFromNode()
                        self?.addNodeToHistory(node: self?.nodeAddress ?? "")
                        self?.fetchMempoolTransactions()
                        self?.blockPollingTimer = Timer.publish(every: 10, on: .main, in: .common) // Increased interval for efficiency
                            .autoconnect()
                            .sink { _ in self?.fetchRecentBlocks() }
                        self?.mempoolPollingTimer = Timer.publish(every: 5, on: .main, in: .common) // Balanced for real-time feel without overload
                            .autoconnect()
                            .sink { _ in self?.fetchMempoolTransactions() }
                        self?.transactionPollingTimer = Timer.publish(every: 30, on: .main, in: .common) // Less frequent as txs change slower
                            .autoconnect()
                            .sink { _ in
                                self?.fetchTransactions()
                                self?.fetchBalance()
                                self?.fetchAddressesBalances()
                                self?.fetchAllWalletAddresses()
                            }
                        self?.statusPollingTimer = Timer.publish(every: 10, on: .main, in: .common)
                            .autoconnect()
                            .sink { _ in self?.refreshNodeInfo() }
                    } else {
                        self?.isConnected = false
                        self?.rpcResponse = "Failed to connect to Bitcoin node."
                        self?.errorMessage = "Invalid response from node."
                        self?.showAlert = true
                    }
                case .failure(let error):
                    self?.isConnected = false
                    self?.rpcResponse = "Failed to connect to Bitcoin node: \(error.localizedDescription). If the node is starting up, please wait a minute and try again."
                    self?.errorMessage = error.localizedDescription
                    self?.showAlert = true
                }
            }
        }
    }
  
    func disconnectNode() {
        isConnected = false
        blockHeight = "--"
        mempoolSize = "--"
        peersConnected = "--"
        syncStatus = "--"
        walletBalance = "--"
        rpcResponse = "Disconnected from your Bitcoin node."
        recentBlocks = []
        nextBlockCandidate = nil
        transactions = []
        blockPollingTimer?.cancel()
        mempoolPollingTimer?.cancel()
        transactionPollingTimer?.cancel()
        statusPollingTimer?.cancel()
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
                DispatchQueue.main.async {
                    if let blocks = resultDict["blocks"] {
                        self?.blockHeight = "\(blocks)"
                    }
                    if let progress = resultDict["verificationprogress"] as? Double {
                        self?.syncStatus = String(format: "%.2f%%", progress * 100)
                    }
                }
            }
            group.leave()
        }
        group.enter()
        rpcService?.sendRPC(method: "getnetworkinfo", params: []) { [weak self] result in
            if case .success(let json) = result,
               let dict = json as? [String: Any],
               let resultDict = dict["result"] as? [String: Any],
               let connections = resultDict["connections"] as? Int {
                DispatchQueue.main.async {
                    self?.peersConnected = "\(connections)"
                }
            }
            group.leave()
        }
        group.enter()
        rpcService?.sendRPC(method: "getmempoolinfo", params: []) { [weak self] result in
            if case .success(let json) = result,
               let dict = json as? [String: Any],
               let resultDict = dict["result"] as? [String: Any],
               let size = resultDict["size"] as? Int {
                DispatchQueue.main.async {
                    self?.mempoolSize = "\(size)"
                }
            }
            group.leave()
        }
        group.notify(queue: .main, execute: {
            self.isLoading = false
            if !self.privacyMode {
                self.fetchBalance()
            }
        })
    }
  
    func fetchBalance() {
        guard isConnected, selectedWallet != nil else { return }
        isLoading = true
        sendWalletRPC(method: "getbalance", params: []) { [weak self] (result: Result<Any, Error>) in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let balance = dict["result"] as? Double {
                        self?.walletBalance = String(format: "%.8f", balance)
                    } else {
                        self?.walletBalance = "0.00000000"
                    }
                case .failure(let error):
                    self?.walletBalance = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
  
    func fetchRecentBlocks() {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "getblockcount", params: []) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let count = dict["result"] as? Int {
                        let previousHeight = Int(self?.blockHeight ?? "0") ?? 0
                        if count > previousHeight {
                            self?.nextBlockFilled()
                        }
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
                                } else {
                                    group.leave()
                                }
                            }
                        }
                        group.notify(queue: .main) {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                self?.recentBlocks = blocks.sorted { $0.height > $1.height }
                            }
                        }
                    }
                case .failure(let error):
                    print("Error fetching block count: \(error.localizedDescription)")
                }
            }
        }
    }
  
    func nextBlockFilled() {
        mempoolEntries = []
        fetchRecentBlocks()
        refreshNodeInfo()
    }
  
    // Wallet Functions
  
    func createNewWallet(name: String) {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "createwallet", params: [name]) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(_):
                    self?.listWalletsFromNode()
                    self?.selectedWallet = self?.wallets.first(where: { $0.name == name })
                    self?.rpcResponse = "Created new wallet: " + name
                case .failure(let error):
                    self?.rpcResponse = "Error creating wallet: " + error.localizedDescription
                }
            }
        }
    }
  
    func sendWalletRPC(method: String, params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        guard let wallet = selectedWallet else {
            completion(.failure(NSError(domain: "", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "No wallet selected."])))
            return
        }
        let urlString = "http://\(nodeAddress):\(rpcPort)/wallet/\(wallet.name)"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain:"", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey:"Invalid wallet RPC URL."])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let credentials = "\(rpcUser):\(rpcPassword)"
        guard let credData = credentials.data(using: .utf8) else {
            completion(.failure(NSError(domain:"", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey:"Error encoding credentials."])))
            return
        }
        let base64Creds = credData.base64EncodedString()
        request.setValue("Basic \(base64Creds)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "jsonrpc": "1.0",
            "id": "swift-ui",
            "method": method,
            "params": params
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain:"", code: 0,
                                            userInfo: [NSLocalizedDescriptionKey:"No data received."])))
                return
            }
            do {
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                completion(.success(json))
            } catch {
                completion(.failure(error))
            }
        }.resume()
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
            self.transactionSendStatus = .failure(reason: "Invalid amount.")
            return
        }
       
        let balanceNumber = NSDecimalNumber(string: walletBalance)
        if amountNumber.compare(balanceNumber) == .orderedDescending {
            self.transactionSendStatus = .failure(reason: "Insufficient Bitcoin balance.")
            self.errorMessage = "Insufficient Bitcoin balance."
            self.showAlert = true
            return
        }
       
        let feeRate: Double
        switch feeOption {
        case .low:
            feeRate = 0.00000500
        case .standard:
            feeRate = 0.00001400
        case .high:
            feeRate = 0.00002000
        case .custom:
            guard let customRate = Double(customFeeRate) else {
                self.transactionSendStatus = .failure(reason: "Invalid custom fee rate.")
                return
            }
            feeRate = customRate
        }
       
        transactionSendStatus = .processing
        isLoading = true
       
        sendWalletRPC(method: "settxfee", params: [feeRate]) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(_):
                    self?.sendWalletRPC(method: "sendtoaddress", params: [self?.recipientAddress ?? "", amountNumber]) { result in
                        DispatchQueue.main.async {
                            self?.isLoading = false
                            switch result {
                            case .success(let json):
                                if let dict = json as? [String: Any],
                                   let txid = dict["result"] as? String {
                                    self?.transactionSendStatus = .success(txid: txid)
                                    self?.rpcResponse = "Sent BTC. Transaction ID: " + txid
                                    let pendingTx = TransactionModel(txid: txid, amount: amountNumber.doubleValue, confirmations: 0, walletName: self?.selectedWallet?.name ?? "Unknown")
                                    self?.transactions.insert(pendingTx, at: 0)
                                    if let wallet = self?.selectedWallet,
                                       let index = wallet.addresses.firstIndex(where: { $0.address == self?.recipientAddress }) {
                                        wallet.addresses[index].isUsed = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                                        self?.transactionSendStatus = .idle
                                    }
                                } else {
                                    let resp = String(describing: json)
                                    self?.transactionSendStatus = .failure(reason: "Unexpected response: " + resp)
                                    self?.rpcResponse = "Sent BTC. Response: " + resp
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                                        self?.transactionSendStatus = .idle
                                    }
                                }
                            case .failure(let error):
                                self?.transactionSendStatus = .failure(reason: error.localizedDescription)
                                self?.rpcResponse = "Error sending BTC: " + error.localizedDescription
                                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                                    self?.transactionSendStatus = .idle
                                }
                            }
                        }
                    }
                case .failure(let error):
                    self?.isLoading = false
                    self?.transactionSendStatus = .failure(reason: "Failed to set fee: " + error.localizedDescription)
                    self?.rpcResponse = "Failed to set fee: " + error.localizedDescription
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                        self?.transactionSendStatus = .idle
                    }
                }
            }
        }
    }
  
    func generateAddress(attempt: Int = 0) {
        if selectedWallet == nil {
            if let firstWallet = wallets.first {
                selectedWallet = firstWallet
            } else {
                self.rpcResponse = "No wallet available. Please create or load a wallet."
                return
            }
        }
        guard let wallet = selectedWallet else {
            self.rpcResponse = "No wallet selected."
            return
        }
        guard attempt < 3 else {
            self.rpcResponse = "Failed to generate a unique address after several attempts."
            return
        }
        isLoading = true
        sendWalletRPC(method: "getnewaddress", params: ["", selectedAddressType]) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any] {
                        if let errorObj = dict["error"] as? [String: Any],
                           let errMsg = errorObj["message"] as? String {
                            self?.rpcResponse = "Error from node: " + errMsg
                            return
                        }
                        if let addr = dict["result"] as? String {
                            if wallet.addresses.contains(where: { $0.address == addr }) {
                                self?.generateAddress(attempt: attempt + 1)
                            } else {
                                wallet.usedAddresses.insert(addr)
                                let newAddress = WalletAddress(address: addr, label: nil, balance: 0.0, isUsed: false)
                                wallet.addresses.append(newAddress)
                                self?.generatedAddress = addr
                                self?.rpcResponse = "New address generated: " + addr
                            }
                        } else {
                            self?.rpcResponse = "Unexpected response when generating address: " + String(describing: json)
                        }
                    } else {
                        self?.rpcResponse = "Unexpected response format when generating address."
                    }
                case .failure(let error):
                    self?.rpcResponse = "Error generating address: " + error.localizedDescription
                }
            }
        }
    }
  
    func fetchTransactions() {
        isLoading = true
        sendWalletRPC(method: "listtransactions", params: ["*", 1000]) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let txArray = dict["result"] as? [[String: Any]] {
                        self?.transactions = Array(txArray.compactMap { tx in
                            guard let txid = tx["txid"] as? String,
                                  let amount = tx["amount"] as? Double,
                                  let confirmations = tx["confirmations"] as? Int else {
                                return nil
                            }
                            return TransactionModel(txid: txid, amount: amount, confirmations: confirmations, walletName: self?.selectedWallet?.name ?? "Unknown")
                        }.reversed())
                        self?.rpcResponse = "Transaction history updated."
                    }
                case .failure(let error):
                    self?.rpcResponse = "Error fetching transactions: " + error.localizedDescription
                }
            }
        }
    }
  
    func executeRPC() {
        guard !rpcCommand.isEmpty else { return }
        isLoading = true
        rpcService?.sendRPC(method: rpcCommand, params: []) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let json):
                    let resp = String(describing: json)
                    self?.rpcResponse = "Response: " + resp
                case .failure(let error):
                    self?.rpcResponse = "Error executing command: " + error.localizedDescription
                }
            }
        }
    }
  
    func listWalletsFromNode() {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "listwalletdir", params: []) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let resultDict = dict["result"] as? [String: Any],
                       let walletsArray = resultDict["wallets"] as? [[String: Any]] {
                        var discoveredWallets: [WalletModel] = []
                        for walletDict in walletsArray {
                            if let name = walletDict["name"] as? String {
                                discoveredWallets.append(WalletModel(name: name))
                            }
                        }
                        self?.wallets = discoveredWallets
                        if self?.selectedWallet == nil, let first = discoveredWallets.first {
                            self?.selectedWallet = first
                        }
                    }
                case .failure(let error):
                    print("Error listing wallets: " + error.localizedDescription)
                }
            }
        }
    }
  
    func selectWallet(wallet: WalletModel) {
        guard isConnected, let rpcService = rpcService else { return }
        rpcService.sendRPC(method: "loadwallet", params: [wallet.name]) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(_):
                    self?.selectedWallet = wallet
                    self?.rpcResponse = "Loaded wallet: " + wallet.name
                case .failure(let error):
                    self?.rpcResponse = "Error loading wallet: " + error.localizedDescription
                }
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
}

// Extension for Dynamic Address Balances
extension BitcoinNodeViewModel {
    func fetchAddressesBalances() {
        guard let wallet = selectedWallet else { return }
        sendWalletRPC(method: "listunspent", params: [0, 9999999, []]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let utxos = dict["result"] as? [[String: Any]] {
                        var balances: [String: Double] = [:]
                        for utxo in utxos {
                            if let address = utxo["address"] as? String,
                               let amount = utxo["amount"] as? Double {
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
    }
}

// Extension for Fetching All Generated Addresses
extension BitcoinNodeViewModel {
    func fetchAllWalletAddresses() {
        guard let _ = selectedWallet else { return }
        sendWalletRPC(method: "listlabels", params: []) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let labels = json as? [String], !labels.isEmpty {
                        var allAddresses: [WalletAddress] = []
                        let group = DispatchGroup()
                        for label in labels {
                            group.enter()
                            self?.sendWalletRPC(method: "getaddressesbylabel", params: [label]) { result in
                                DispatchQueue.main.async {
                                    if case .success(let json2) = result,
                                       let dict = json2 as? [String: Any],
                                       let addressesDict = dict["result"] as? [String: Any] {
                                        for (address, detailsAny) in addressesDict {
                                            if let details = detailsAny as? [String: Any] {
                                                let balance = details["balance"] as? Double ?? 0.0
                                                let lbl = details["label"] as? String
                                                let isUsed = balance > 0.0
                                                allAddresses.append(WalletAddress(address: address, label: lbl, balance: balance, isUsed: isUsed))
                                            }
                                        }
                                    }
                                    group.leave()
                                }
                            }
                        }
                        group.notify(queue: .main) {
                            self?.selectedWallet?.addresses = allAddresses
                        }
                    } else {
                        self?.sendWalletRPC(method: "getaddressesbylabel", params: [""]) { result in
                            DispatchQueue.main.async {
                                if case .success(let json2) = result,
                                   let dict = json2 as? [String: Any],
                                   let addressesDict = dict["result"] as? [String: Any] {
                                    var allAddresses: [WalletAddress] = []
                                    for (address, detailsAny) in addressesDict {
                                        if let details = detailsAny as? [String: Any] {
                                            let balance = details["balance"] as? Double ?? 0.0
                                            let lbl = details["label"] as? String
                                            let isUsed = balance > 0.0
                                            allAddresses.append(WalletAddress(address: address, label: lbl, balance: balance, isUsed: isUsed))
                                        }
                                    }
                                    self?.selectedWallet?.addresses = allAddresses
                                }
                            }
                        }
                    }
                case .failure(let error):
                    print("Error fetching labels: \(error.localizedDescription)")
                }
            }
        }
    }
}

// Transaction Row View
struct TransactionRowView: View {
    let transaction: TransactionModel
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HighlightableText(text: "TXID: \(transaction.txid)")
                    .font(.subheadline)
                    .lineLimit(1)
                Text("Confirmations: \(transaction.confirmations > 10 ? "10+" : "\(transaction.confirmations)")")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            Text("\(transaction.amount, specifier: "%.8f") BTC")
                .foregroundColor(transaction.amount < 0 ? .red : .green)
        }
        .padding(5)
    }
}

// Transaction Detail View
struct TransactionDetailView: View {
    let transaction: TransactionModel
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var transactionDetails: [String: Any] = [:]
    @State private var loading: Bool = true
    @State private var error: String?
    @Environment(\.presentationMode) var presentationMode
  
    private var shortTxID: String {
        return String(transaction.txid.prefix(8))
    }
  
    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView("Loading Transaction Details...")
                } else if let error = error {
                    Text("Error: " + error)
                } else {
                    ScrollView {
                        TransactionDetailsView(details: transactionDetails)
                    }
                }
            }
            .navigationTitle("TX " + shortTxID + "...")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                fetchDetails()
            }
        }
    }
  
    func fetchDetails() {
        viewModel.sendWalletRPC(method: "gettransaction", params: [transaction.txid]) { result in
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any] {
                        if let resultObj = dict["result"] {
                            if let resultDict = resultObj as? [String: Any] {
                                transactionDetails = resultDict
                            } else {
                                transactionDetails = ["result": resultObj]
                            }
                        } else if let errorObj = dict["error"] as? [String: Any],
                                  let errMsg = errorObj["message"] as? String {
                            error = errMsg
                        } else {
                            error = "Unexpected response format"
                        }
                    } else {
                        error = "Unexpected response format"
                    }
                case .failure(let err):
                    error = err.localizedDescription
                }
            }
        }
    }
}

// Mempool Tx Detail View
struct MempoolTxDetailView: View {
    let txid: String
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var transactionDetails: [String: Any] = [:]
    @State private var loading: Bool = true
    @State private var error: String?
    @Environment(\.presentationMode) var presentationMode
  
    private var shortTxID: String {
        return String(txid.prefix(8))
    }
  
    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView("Loading Transaction Details...")
                } else if let error = error {
                    Text("Error: " + error)
                } else {
                    ScrollView {
                        TransactionDetailsView(details: transactionDetails)
                    }
                }
            }
            .navigationTitle("Mempool TX " + shortTxID + "...")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                fetchDetails()
            }
        }
    }
  
    func fetchDetails() {
        viewModel.rpcService?.sendRPC(method: "getrawtransaction", params: [txid, true]) { result in
            DispatchQueue.main.async {
                loading = false
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any] {
                        if let resultObj = dict["result"] {
                            if let resultDict = resultObj as? [String: Any] {
                                transactionDetails = resultDict
                            } else {
                                transactionDetails = ["result": resultObj]
                            }
                        } else if let errorObj = dict["error"] as? [String: Any],
                                  let errMsg = errorObj["message"] as? String {
                            error = errMsg
                        } else {
                            error = "Unexpected response format"
                        }
                    } else {
                        error = "Unexpected response format"
                    }
                case .failure(let err):
                    error = err.localizedDescription
                }
            }
        }
    }
}

// New Wallet Sheet View
struct NewWalletSheetView: View {
    @Binding var walletName: String
    var onCreate: () -> Void
    var onCancel: () -> Void
  
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("New Wallet Name")) {
                    TextField("Wallet Name", text: $walletName)
                }
            }
            .navigationTitle("Create New Wallet")
            .navigationBarItems(leading: Button("Cancel") { onCancel() },
                                trailing: Button("Create") { onCreate() })
        }
    }
}

// Block Detail View
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
                    if let height = blockDetails["height"] as? Int {
                        HStack {
                            Text("Block")
                            Spacer()
                            Text("\(height)")
                        }
                    }
                    if let hash = blockDetails["hash"] as? String {
                        let displayHash = String(hash.prefix(2)) + ".." + String(hash.suffix(6))
                        HStack {
                            Text("Hash")
                            Spacer()
                            Text(displayHash)
                        }
                    }
                    if let timeInt = blockDetails["time"] as? Int {
                        let date = Date(timeIntervalSince1970: TimeInterval(timeInt))
                        HStack {
                            Text("Timestamp")
                            Spacer()
                            Text(dateFormatted(date: date))
                        }
                        HStack {
                            Text("Relative Time")
                            Spacer()
                            Text(relativeTime(from: date))
                        }
                    }
                    if let size = blockDetails["size"] as? Int {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text(String(format: "%.2f MB", Double(size) / 1_000_000.0))
                        }
                    }
                    if let weight = blockDetails["weight"] as? Int {
                        HStack {
                            Text("Weight")
                            Spacer()
                            Text(String(format: "%.2f MWU", Double(weight) / 1_000_000.0))
                        }
                    }
                    if let nTx = blockDetails["nTx"] as? Int {
                        HStack {
                            Text("Transactions")
                            Spacer()
                            Text("\(nTx)")
                        }
                    }
                }
                if !blockStats.isEmpty {
                    Section(header: Text("Fee Statistics")) {
                        if let feerange = blockStats["feerange"] as? [Double], feerange.count >= 2 {
                            HStack {
                                Text("Fee Span")
                                Spacer()
                                Text("\(Int(feerange[0])) - \(Int(feerange[1])) sat/vB")
                            }
                        }
                        if let medianfee = blockStats["medianfeerate"] as? Double {
                            HStack {
                                Text("Median Fee")
                                Spacer()
                                let feeBTC = medianfee / 100_000_000.0
                                Text(String(format: "~%.8f BTC/vB", feeBTC))
                            }
                        }
                        if let totalfee = blockStats["totalfee"] as? Double {
                            HStack {
                                Text("Total Fees")
                                Spacer()
                                let feeBTC = totalfee / 100_000_000.0
                                Text(String(format: "%.8f BTC", feeBTC))
                            }
                        }
                        if let subsidy = blockStats["subsidy"] as? Double,
                           let totalfee = blockStats["totalfee"] as? Double {
                            HStack {
                                Text("Subsidy + Fees")
                                Spacer()
                                let subsidyBTC = subsidy / 100_000_000.0
                                let feeBTC = totalfee / 100_000_000.0
                                Text(String(format: "%.8f BTC", subsidyBTC + feeBTC))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Block Detail")
            .navigationBarItems(trailing: Button("Done") {
                presentationMode.wrappedValue.dismiss()
            })
            .onAppear {
                fetchBlockData()
            }
        }
    }
  
    func fetchBlockData() {
        viewModel.rpcService?.sendRPC(method: "getblock", params: [blockHash, 2]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let resultDict = dict["result"] as? [String: Any] {
                        self.blockDetails = resultDict
                    }
                case .failure(let error):
                    self.blockDetails = ["error": error.localizedDescription]
                }
                fetchBlockStats()
            }
        }
    }
  
    func fetchBlockStats() {
        viewModel.rpcService?.sendRPC(method: "getblockstats", params: [blockHash]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let json):
                    if let dict = json as? [String: Any],
                       let resultDict = dict["result"] as? [String: Any] {
                        self.blockStats = resultDict
                    }
                case .failure(let error):
                    self.blockStats = ["error": error.localizedDescription]
                }
            }
        }
    }
  
    func dateFormatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
  
    func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        } else if interval < 2419200 {
            let weeks = Int(interval / 604800)
            return "\(weeks) week\(weeks == 1 ? "" : "s") ago"
        } else {
            let months = Int(interval / 2419200)
            return "\(months) month\(months == 1 ? "" : "s") ago"
        }
    }
}

// Dashboard View
struct DashboardView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var selectedBlock: BlockInfo? = nil
    @State private var selectedMempoolEntry: MempoolEntry? = nil
  
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if let currentHeight = Int(viewModel.blockHeight) {
                        Text("Next Block Height: \(currentHeight + 1)")
                            .font(.headline)
                    }
                    VStack(spacing: 10) {
                        HStack {
                            if let candidate = viewModel.nextBlockCandidate {
                                VStack {
                                    Text("Next Block")
                                        .font(.caption)
                                    Text("Mempool: \(candidate.mempoolTxCount) txs")
                                        .font(.headline)
                                }
                                .padding()
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                            Spacer()
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(viewModel.recentBlocks) { block in
                                        VStack {
                                            Text("H: \(block.height)")
                                                .font(.caption)
                                            let shortHash = String(block.hash.prefix(2)) + ".." + String(block.hash.suffix(6))
                                            Text(shortHash)
                                                .font(.caption2)
                                            Text(Date(timeIntervalSince1970: TimeInterval(block.time)), style: .time)
                                                .font(.caption2)
                                        }
                                        .padding()
                                        .background(Color(UIColor.secondarySystemBackground))
                                        .cornerRadius(8)
                                        .onTapGesture {
                                            selectedBlock = block
                                        }
                                        .transition(.move(edge: .leading))
                                    }
                                }
                                .animation(.easeInOut(duration: 0.5), value: viewModel.recentBlocks)
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.systemGroupedBackground))
                    .cornerRadius(8)
                   
                    HStack {
                        Text("Wallet: \(viewModel.selectedWallet?.name ?? "None")")
                            .font(.subheadline)
                        Spacer()
                        if viewModel.privacyMode {
                            Text("Balance: Hidden")
                                .font(.subheadline)
                        } else {
                            let balanceToDisplay = (Double(viewModel.walletBalance) != nil) ? String(format: "%.8f", Double(viewModel.walletBalance)!) : "0"
                            Text("Balance: \(balanceToDisplay) BTC")
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                   
                    VStack(spacing: 5) {
                        Text("Bitcoin Node Status")
                            .font(.title)
                            .bold()
                        HStack {
                            Circle()
                                .fill(viewModel.isConnected ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            Text(viewModel.isConnected ? "Connected" : "Not Connected")
                                .foregroundColor(viewModel.isConnected ? .green : .red)
                        }
                    }
                   
                    if viewModel.isConnected {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Block Height: \(viewModel.blockHeight)")
                            Text("Mempool Size: \(viewModel.mempoolSize) txs")
                            Text("Peers Connected: \(viewModel.peersConnected)")
                            Text("Sync Status: \(viewModel.syncStatus)")
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                       
                        Text("Next Block Preview")
                            .font(.headline)
                            .padding(.top)
                       
                        AnimatedNextBlockView(mempoolEntries: viewModel.mempoolEntries, onSelect: { self.selectedMempoolEntry = $0 })
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .sheet(item: $selectedBlock) { block in
                BlockDetailView(blockHash: block.hash, viewModel: viewModel)
            }
            .sheet(item: $selectedMempoolEntry) { entry in
                MempoolTxDetailView(txid: entry.txid, viewModel: viewModel)
            }
        }
        .navigationViewStyle(.stack)
    }
}

// Wallet View
struct WalletView: View {
    @ObservedObject var viewModel: BitcoinNodeViewModel
    @State private var showNewWalletSheet = false
    @State private var newWalletName: String = ""
    @State private var selectedTransaction: TransactionModel? = nil
    @State private var showSendConfirmation: Bool = false
  
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 20) { // Use LazyVStack for better performance
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Wallet Management")
                            .font(.headline)
                        if viewModel.wallets.isEmpty {
                            Text("No wallets discovered on the node.")
                                .foregroundColor(.gray)
                        } else {
                            ForEach(viewModel.wallets, id: \.id) { wallet in
                                HStack {
                                    Text(wallet.name)
                                    Spacer()
                                    if viewModel.selectedWallet == wallet {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else {
                                        Button("Load") {
                                            viewModel.selectWallet(wallet: wallet)
                                        }
                                        .foregroundColor(.blue)
                                    }
                                }
                                .padding(5)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                        }
                        Button(action: { showNewWalletSheet = true }) {
                            Text("Create New Wallet")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.systemGroupedBackground))
                    .cornerRadius(8)
                   
                   
                   
                    HStack {
                        Text("Current Wallet: \(viewModel.selectedWallet?.name ?? "None")")
                            .font(.subheadline)
                        Spacer()
                        if viewModel.privacyMode {
                            Text("Balance: Hidden")
                                .font(.subheadline)
                        } else {
                            let balanceToDisplay = (Double(viewModel.walletBalance) != nil) ? String(format: "%.8f", Double(viewModel.walletBalance)!) : "0"
                            Text("Balance: \(balanceToDisplay) BTC")
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(8)
                    .padding(.horizontal)
                   
                    if viewModel.selectedWallet != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Select Address Format")
                                .font(.subheadline)
                            Picker("Address Format", selection: $viewModel.selectedAddressType) {
                                Text("Legacy").tag("legacy")
                                Text("P2SH-Segwit").tag("p2sh-segwit")
                                Text("Bech32").tag("bech32")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }
                        .padding(.horizontal)
                    }
                   
                    if viewModel.selectedWallet != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Send Bitcoin").bold()
                            TextField("Recipient Address", text: $viewModel.recipientAddress)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            TextField("Amount (BTC)", text: $viewModel.amountBTC)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                           
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Select Fee Option")
                                Picker("Fee Option", selection: $viewModel.feeOption) {
                                    ForEach(BitcoinNodeViewModel.FeeOption.allCases) { option in
                                        Text(option.rawValue).tag(option)
                                    }
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                if viewModel.feeOption == .custom {
                                    TextField("Custom Fee Rate (BTC/kB)", text: $viewModel.customFeeRate)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                }
                            }
                           
                            Button(action: {
                                showSendConfirmation = true
                            }) {
                                Text("Send BTC")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                           
                            Group {
                                switch viewModel.transactionSendStatus {
                                case .idle:
                                    EmptyView()
                                case .processing:
                                    ProgressView("Sending...")
                                case .success(let txid):
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("Transaction sent: \(txid)")
                                        Button(action: {
                                            UIPasteboard.general.string = txid
                                        }) {
                                            Image(systemName: "doc.on.doc")
                                        }
                                    }
                                case .failure(let reason):
                                    Text("Error: \(reason)")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.top, 5)
                           
                            VStack(spacing: 10) {
                                Text("Receive Bitcoin").bold()
                                Button(action: { viewModel.generateAddress() }) {
                                    Text("Generate New Address")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                                HStack {
                                    Text(viewModel.generatedAddress)
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                    Button(action: {
                                        UIPasteboard.general.string = viewModel.generatedAddress
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                       
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Wallet Transactions (Wallet: \(viewModel.selectedWallet?.name ?? "Unknown"))")
                                .font(.headline)
                            ForEach(viewModel.transactions, id: \.id) { tx in
                                Button(action: {
                                    selectedTransaction = tx
                                }) {
                                    TransactionRowView(transaction: tx)
                                }
                            }
                        }
                        .padding()
                        .background(Color(UIColor.systemGroupedBackground))
                        .cornerRadius(8)
                    } else {
                        Text("Please create and load a wallet to access wallet functions.")
                            .foregroundColor(.gray)
                    }
                }
                .padding()
            }
            .navigationTitle("Wallet")
            .sheet(isPresented: $showNewWalletSheet) {
                NewWalletSheetView(walletName: $newWalletName, onCreate: {
                    viewModel.createNewWallet(name: newWalletName)
                    newWalletName = ""
                    showNewWalletSheet = false
                }, onCancel: {
                    newWalletName = ""
                    showNewWalletSheet = false
                })
            }
            .sheet(item: $selectedTransaction) { tx in
                TransactionDetailView(transaction: tx, viewModel: viewModel)
            }
            .alert(isPresented: $showSendConfirmation) {
                Alert(title: Text("Confirm Transaction"),
                      message: Text("Are you sure you want to send \(viewModel.amountBTC) BTC to \(viewModel.recipientAddress)?"),
                      primaryButton: .destructive(Text("Send")) {
                        viewModel.sendBitcoin()
                      },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(.stack)
    }
}

// Terminal View
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
                    ForEach(0..<segments.count, id: \.self) { index in
                        Text(segments[index]).tag(index)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                if selectedSegment == 0 {
                    VStack(spacing: 10) {
                        TextField("Enter RPC Command", text: $viewModel.rpcCommand)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Button(action: { viewModel.executeRPC() }) {
                            Text("Execute")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .padding(.horizontal)
                        Divider().padding(.horizontal)
                        ScrollView {
                            Text(viewModel.rpcResponse)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.gray)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        .padding()
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(helpCommands, id: \.self) { cmd in
                                Text(cmd)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(5)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(5)
                            }
                        }
                        .padding()
                    }
                }
                Spacer()
            }
            .navigationTitle("Terminal")
        }
        .navigationViewStyle(.stack)
    }
}

// Settings View
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
                        Circle()
                            .fill(viewModel.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(viewModel.isConnected ? "Connected" : "Not Connected")
                    }
                    if viewModel.isConnected {
                        Button("Disconnect") {
                            viewModel.disconnectNode()
                        }
                        .foregroundColor(.red)
                    } else {
                        Button("Connect") {
                            viewModel.connectToNode()
                        }
                        .foregroundColor(.blue)
                    }
                }
                Section(header: Text("Node History")) {
                    if viewModel.nodeHistory.isEmpty {
                        Text("No nodes in history.")
                            .foregroundColor(.gray)
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
                        Button("Purge History") {
                            viewModel.purgeNodeHistory()
                        }
                        .foregroundColor(.red)
                    }
                }
                Section(header: Text("Preferences")) {
                    Toggle("Remember Me", isOn: $viewModel.rememberMe)
                    Toggle("Privacy Mode (Hide Balance)", isOn: $viewModel.privacyMode)
                }
                Section(header: Text("Appearance")) {
                    Toggle("Dark Mode", isOn: $isDarkMode)
                }
                Section(header: Text("Reset")) {
                    Button("Purge Everything") {
                        showPurgeAlert = true
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Settings")
            .alert(isPresented: $showPurgeAlert) {
                Alert(title: Text("Warning"),
                      message: Text("Are you sure? This will wipe all data from this device."),
                      primaryButton: .destructive(Text("Purge")) {
                        viewModel.purgeAllData()
                      },
                      secondaryButton: .cancel())
            }
        }
        .navigationViewStyle(.stack)
    }
}

// ContentView
struct ContentView: View {
    @AppStorage("isDarkMode") private var isDarkMode: Bool = false
    @StateObject var viewModel = BitcoinNodeViewModel()
  
    var body: some View {
        TabView {
            DashboardView(viewModel: viewModel)
                .tabItem {
                    Label("Dashboard", systemImage: "speedometer")
                }
            WalletView(viewModel: viewModel)
                .tabItem {
                    Label("Wallet", systemImage: "wallet.pass")
                }
            TerminalView(viewModel: viewModel)
                .tabItem {
                    Label("Terminal", systemImage: "terminal.fill")
                }
            SettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .alert(isPresented: $viewModel.showAlert) {
            Alert(title: Text("Error"),
                  message: Text(viewModel.errorMessage ?? "Unknown error"),
                  dismissButton: .default(Text("OK")))
        }
    }
}

// Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}