import RxSwift
import HdWalletKit
import BigInt
import OpenSslKit
import Secp256k1Kit
import HsToolKit

public class Kit {
    public static let defaultGasLimit = 21_000

    private let maxGasLimit = 1_000_000
    private let defaultMinAmount: BigUInt = 1

    private let lastBlockHeightSubject = PublishSubject<Int>()
    private let syncStateSubject = PublishSubject<SyncState>()
    private let transactionsSyncStateSubject = PublishSubject<SyncState>()
    private let balanceSubject = PublishSubject<String>()
    private let transactionsSubject = PublishSubject<[TransactionInfo]>()

    private let blockchain: IBlockchain
    private let transactionManager: ITransactionManager
    private let transactionBuilder: TransactionBuilder
    private let state: EthereumKitState

    public let address: Data

    public let uniqueId: String
    public let etherscanApiProvider: EtherscanApiProvider

    public let logger: Logger

    init(blockchain: IBlockchain, transactionManager: ITransactionManager, transactionBuilder: TransactionBuilder, state: EthereumKitState = EthereumKitState(), address: Data, uniqueId: String, etherscanApiProvider: EtherscanApiProvider, logger: Logger) {
        self.blockchain = blockchain
        self.transactionManager = transactionManager
        self.transactionBuilder = transactionBuilder
        self.state = state
        self.address = address
        self.uniqueId = uniqueId
        self.etherscanApiProvider = etherscanApiProvider
        self.logger = logger

        state.balance = blockchain.balance
        state.lastBlockHeight = blockchain.lastBlockHeight
    }

}

// Public API Extension

extension Kit {

    public var lastBlockHeight: Int? {
        state.lastBlockHeight
    }

    public var balance: String? {
        state.balance?.description
    }

    public var syncState: SyncState {
        blockchain.syncState
    }

    public var transactionsSyncState: SyncState {
        transactionManager.syncState
    }

    public var receiveAddress: String {
        address.toEIP55Address()
    }

    public var lastBlockHeightObservable: Observable<Int> {
        lastBlockHeightSubject.asObservable()
    }

    public var syncStateObservable: Observable<SyncState> {
        syncStateSubject.asObservable()
    }

    public var transactionsSyncStateObservable: Observable<SyncState> {
        transactionsSyncStateSubject.asObservable()
    }

    public var balanceObservable: Observable<String> {
        balanceSubject.asObservable()
    }

    public var transactionsObservable: Observable<[TransactionInfo]> {
        transactionsSubject.asObservable()
    }

    public func start() {
        blockchain.start()
        transactionManager.refresh()
    }

    public func stop() {
        blockchain.stop()
    }

    public func refresh() {
        blockchain.refresh()
        transactionManager.refresh()
    }

    public static func validate(address: String) throws {
        try AddressValidator.validate(address: address)
    }

    public func transactionsSingle(fromHash: String? = nil, limit: Int? = nil) -> Single<[TransactionInfo]> {
        transactionManager.transactionsSingle(fromHash: fromHash.flatMap { Data(hex: $0) }, limit: limit)
                .map { $0.map { TransactionInfo(transaction: $0) } }
    }

    public func transaction(hash: String) -> TransactionInfo? {
        guard let hash = Data(hex: hash) else {
            return nil
        }

        return transactionManager.transaction(hash: hash).map { TransactionInfo(transaction: $0) }
    }

    public func sendSingle(address: Data, value: BigUInt, transactionInput: Data = Data(), gasPrice: Int, gasLimit: Int) -> Single<TransactionInfo> {
        let rawTransaction = transactionBuilder.rawTransaction(gasPrice: gasPrice, gasLimit: gasLimit, to: address, value: value, data: transactionInput)

        return blockchain.sendSingle(rawTransaction: rawTransaction)
                .do(onSuccess: { [weak self] transaction in
                    self?.transactionManager.handle(sentTransaction: transaction)
                })
                .map { TransactionInfo(transaction: $0) }
    }

    public func sendSingle(to: String, value: String, gasPrice: Int, gasLimit: Int) -> Single<TransactionInfo> {
        guard let to = Data(hex: to) else {
            return Single.error(ValidationError.invalidAddress)
        }

        guard let value = BigUInt(value) else {
            return Single.error(ValidationError.invalidValue)
        }

        return sendSingle(address: to, value: value, gasPrice: gasPrice, gasLimit: gasLimit)
    }

    public var debugInfo: String {
        var lines = [String]()

        lines.append("ADDRESS: \(address.toEIP55Address())")

        return lines.joined(separator: "\n")
    }

    public func getLogsSingle(address: Data?, topics: [Any?], fromBlock: Int, toBlock: Int, pullTimestamps: Bool) -> Single<[EthereumLog]> {
        blockchain.getLogsSingle(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock, pullTimestamps: pullTimestamps)
    }

    public func transactionStatus(transactionHash: Data) -> Single<TransactionStatus> {
        blockchain.transactionReceiptStatusSingle(transactionHash: transactionHash).flatMap { [unowned self] transactionStatus -> Single<TransactionStatus> in
            switch transactionStatus {
            case .success, .failed:
                return Single.just(transactionStatus)
            default:
                return self.blockchain.transactionExistSingle(transactionHash: transactionHash).flatMap { exist -> Single<TransactionStatus> in
                    Single.just(exist ? .pending : .notFound)
                }
            }
        }
    }

    public func getStorageAt(contractAddress: Data, positionData: Data, blockHeight: Int) -> Single<Data> {
        blockchain.getStorageAt(contractAddress: contractAddress, positionData: positionData, blockHeight: blockHeight)
    }

    public func call(contractAddress: Data, data: Data, blockHeight: Int? = nil) -> Single<Data> {
        blockchain.call(contractAddress: contractAddress, data: data, blockHeight: blockHeight)
    }

    public func estimateGas(to: String?, amount: String, gasPrice: Int?) -> Single<Int> {
        // without address - provide default gas limit
        guard let to = to else {
            return Single.just(Kit.defaultGasLimit)
        }

        guard let toData = Data(hex: to) else {
            return Single.error(ValidationError.invalidAddress)
        }

        guard let amount = BigUInt(amount) else {
            return Single.error(ValidationError.invalidValue)
        }

        // if amount is 0 - set default minimum amount
        let resolvedAmount: BigUInt = amount == 0 ? defaultMinAmount : amount

        return blockchain.estimateGas(to: toData, amount: resolvedAmount, gasLimit: maxGasLimit, gasPrice: gasPrice, data: nil)
    }

    public func estimateGas(to: Data, amount: BigUInt?, gasPrice: Int?, data: Data?) -> Single<Int> {
        blockchain.estimateGas(to: to, amount: amount, gasLimit: maxGasLimit, gasPrice: gasPrice, data: data)
    }

    public func statusInfo() -> [(String, Any)] {
        [
            ("Last Block Height", "\(state.lastBlockHeight.map { "\($0)" } ?? "N/A")"),
            ("Sync State", blockchain.syncState.description),
            ("Blockchain Source", blockchain.source),
            ("Transactions Source", transactionManager.source)
        ]
    }

}


extension Kit: IBlockchainDelegate {

    func onUpdate(lastBlockHeight: Int) {
        guard state.lastBlockHeight != lastBlockHeight else {
            return
        }

        state.lastBlockHeight = lastBlockHeight

        lastBlockHeightSubject.onNext(lastBlockHeight)
    }

    func onUpdate(balance: BigUInt) {
        guard state.balance != balance else {
            return
        }

        state.balance = balance

        balanceSubject.onNext(balance.description)
    }

    func onUpdate(syncState: SyncState) {
        syncStateSubject.onNext(syncState)
    }

}

extension Kit: ITransactionManagerDelegate {

    func onUpdate(transactions: [Transaction]) {
        transactionsSubject.onNext(transactions.map { TransactionInfo(transaction: $0) })
    }

    func onUpdate(transactionsSyncState: SyncState) {
        transactionsSyncStateSubject.onNext(syncState)
    }

}

extension Kit {

    public static func instance(privateKey: Data, syncMode: SyncMode, networkType: NetworkType = .mainNet, rpcApi: RpcApi, etherscanApiKey: String, walletId: String, minLogLevel: Logger.Level = .error) throws -> Kit {
        let logger = Logger(minLogLevel: minLogLevel)

        let uniqueId = "\(walletId)-\(networkType)"

        let publicKey = Data(Secp256k1Kit.Kit.createPublicKey(fromPrivateKeyData: privateKey, compressed: false).dropFirst())
        let address = Data(CryptoUtils.shared.sha3(publicKey).suffix(20))

        let network: INetwork = networkType.network
        let transactionSigner = TransactionSigner(network: network, privateKey: privateKey)
        let transactionBuilder = TransactionBuilder(address: address)
        let networkManager = NetworkManager(logger: logger)

        let etherscanApiProvider = EtherscanApiProvider(networkManager: networkManager, network: network, etherscanApiKey: etherscanApiKey, address: address)
        let transactionsProvider: ITransactionsProvider = EtherscanTransactionProvider(provider: etherscanApiProvider)

        let rpcApiProvider: IRpcApiProvider
        switch rpcApi {
        case let .infura(id, secret):
            rpcApiProvider = InfuraApiProvider(networkManager: networkManager, network: network, id: id, secret: secret, address: address)
        case .incubed:
            rpcApiProvider = IncubedRpcApiProvider(address: address, logger: logger)
        }

        var blockchain: IBlockchain

        switch syncMode {
        case .api:
            let storage: IApiStorage = try ApiStorage(databaseDirectoryUrl: dataDirectoryUrl(), databaseFileName: "api-\(uniqueId)")
            blockchain = ApiBlockchain.instance(storage: storage, transactionSigner: transactionSigner, transactionBuilder: transactionBuilder, rpcApiProvider: rpcApiProvider, logger: logger)
        case .spv(let nodePrivateKey):
            let storage: ISpvStorage = try SpvStorage(databaseDirectoryUrl: dataDirectoryUrl(), databaseFileName: "spv-\(uniqueId)")

            let nodePublicKey = Data(Secp256k1Kit.Kit.createPublicKey(fromPrivateKeyData: nodePrivateKey, compressed: false).dropFirst())
            let nodeKey = ECKey(privateKey: nodePrivateKey, publicKeyPoint: ECPoint(nodeId: nodePublicKey))

            let discoveryStorage = try DiscoveryStorage(databaseDirectoryUrl: dataDirectoryUrl(), databaseFileName: "dcvr-\(uniqueId)")

            let packetSerializer = PacketSerializer(serializers: [
                PingPackageSerializer(),
                PongPackageSerializer(),
                FindNodePackageSerializer(),
            ], privateKey: nodeKey.privateKey)

            let packetParser = PacketParser(parsers: [
                0x01: PingPackageParser(),
                0x02: PongPackageParser(),
                0x04: NeighborsPackageParser(),
            ])

            let udpFactory = UdpFactory(packetSerializer: packetSerializer)
            let nodeFactory = NodeFactory()

            let nodeDiscovery = NodeDiscovery(ecKey: nodeKey, factory: udpFactory, discoveryStorage: discoveryStorage, nodeParser: NodeParser(), packetParser: packetParser)
            let nodeManager = NodeManager(storage: discoveryStorage, nodeDiscovery: nodeDiscovery, nodeFactory: nodeFactory, logger: logger)
            nodeDiscovery.nodeManager = nodeManager

            blockchain = SpvBlockchain.instance(storage: storage, nodeManager: nodeManager, transactionSigner: transactionSigner, transactionBuilder: transactionBuilder, rpcApiProvider: rpcApiProvider, network: network, address: address, nodeKey: nodeKey, logger: logger)
        case .geth:
            fatalError("Geth is not supported")
//            let directoryUrl = try dataDirectoryUrl()
//            let storage: IApiStorage = ApiStorage(databaseDirectoryUrl: directoryUrl, databaseFileName: "geth-\(uniqueId)")
//            let nodeDirectory = directoryUrl.appendingPathComponent("node-\(uniqueId)", isDirectory: true)
//            blockchain = try GethBlockchain.instance(nodeDirectory: nodeDirectory, network: network, storage: storage, transactionSigner: transactionSigner, transactionBuilder: transactionBuilder, address: address, logger: logger)
        }

        let transactionStorage: ITransactionStorage = TransactionStorage(databaseDirectoryUrl: try dataDirectoryUrl(), databaseFileName: "transactions-\(uniqueId)")
        let transactionManager = TransactionManager(storage: transactionStorage, transactionsProvider: transactionsProvider)

        let ethereumKit = Kit(blockchain: blockchain, transactionManager: transactionManager, transactionBuilder: transactionBuilder, address: address, uniqueId: uniqueId, etherscanApiProvider: etherscanApiProvider, logger: logger)

        blockchain.delegate = ethereumKit
        transactionManager.delegate = ethereumKit

        return ethereumKit
    }

    public static func instance(words: [String], syncMode wordsSyncMode: WordsSyncMode, networkType: NetworkType = .mainNet, rpcApi: RpcApi, etherscanApiKey: String, walletId: String, minLogLevel: Logger.Level = .error) throws -> Kit {
        let coinType: UInt32 = networkType == .mainNet ? 60 : 1

        let hdWallet = HDWallet(seed: Mnemonic.seed(mnemonic: words), coinType: coinType, xPrivKey: 0, xPubKey: 0)
        let privateKey = try hdWallet.privateKey(account: 0, index: 0, chain: .external).raw

        let syncMode: SyncMode

        switch wordsSyncMode {
        case .api: syncMode = .api
        case .spv: syncMode = .spv(nodePrivateKey: try hdWallet.privateKey(account: 100, index: 100, chain: .external).raw)
        case .geth: syncMode = .geth
        }

        return try instance(privateKey: privateKey, syncMode: syncMode, networkType: networkType, rpcApi: rpcApi, etherscanApiKey: etherscanApiKey, walletId: walletId, minLogLevel: minLogLevel)
    }

    public static func clear(exceptFor excludedFiles: [String]) throws {
        let fileManager = FileManager.default
        let fileUrls = try fileManager.contentsOfDirectory(at: dataDirectoryUrl(), includingPropertiesForKeys: nil)

        for filename in fileUrls {
            if !excludedFiles.contains(where: { filename.lastPathComponent.contains($0) }) {
                try fileManager.removeItem(at: filename)
            }
        }
    }

    private static func dataDirectoryUrl() throws -> URL {
        let fileManager = FileManager.default

        let url = try fileManager
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ethereum-kit", isDirectory: true)

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

}

extension Kit {

    public enum SyncError: Error {
        case notStarted
        case noNetworkConnection
    }

    public enum AddressValidationError: Error {
        case invalidChecksum
        case invalidAddressLength
        case invalidSymbols
        case wrongAddressPrefix
    }

}
