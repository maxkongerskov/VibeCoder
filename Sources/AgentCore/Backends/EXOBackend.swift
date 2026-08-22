//
//  EXOBackend.swift
//
//  Real EXO adapter. The original AgentOS treated EXO as a port alias
//  over LMStudioService — same wire protocol, different default port.
//  That works for inference but means the user can never see their
//  cluster.
//
//  NEW DAY queries EXO's `/state` endpoint to surface the actual node
//  graph: each Mac's device model, chip, pooled RAM, live GPU load, and
//  which node is the current coordinator. Inference goes through the same
//  `/v1/chat/completions` surface as LM Studio, but topology errors
//  ("node dropped during streaming") bubble up with real context.
//
//  EXO's real API (src/exo/master/api.py) exposes cluster state as:
//    GET /state    → { topology: { nodes: [peerID...] },
//                      nodeIdentities: { peerID: { modelId, chipId,
//                                                  friendlyName } },
//                      nodeMemory:     { peerID: { ramTotal:{inBytes},
//                                                  ramAvailable:{inBytes} } },
//                      nodeSystem:     { peerID: { gpuUsage, temp, ... } },
//                      instances:      { id: { <Type>: { shardAssignments:
//                                            { modelId, nodeToRunner } } } } }
//    GET /node_id  → "peerID"   (the current master / coordinator)
//  There is NO /v1/topology on current EXO — that was the old guess.
//  All fields are decoded defensively (optional) so version drift
//  degrades gracefully instead of failing the whole panel.
//

import Foundation

public actor EXOBackend: InferenceBackend {
    public let identifier: BackendIdentifier = .exo
    private let client: OpenAICompatibleClient
    private let stateURL: URL
    private let nodeIDURL: URL
    private let modelsURL: URL
    private let downloadedModelsURL: URL
    private var cachedTopology: ClusterTopology?
    /// The single model ID the user told us EXO has loaded. EXO's
    /// `/v1/models` returns the *catalog* of every model EXO could
    /// serve (often 100+), not what's actually loaded — surfacing
    /// that list in the chat picker confuses users into selecting
    /// models that then fail at first turn. We trust the user's
    /// Settings → Connection → EXO → Model ID field instead.
    private let pinnedModelID: String?

    public init(
        host: String = "127.0.0.1",
        port: Int = 52415,
        pinnedModelID: String? = nil,
        requestTimeout: TimeInterval = 600
    ) {
        // Defensive: a caller (or a corrupted persisted setting) may pass a
        // host that already includes a scheme like "http://" or a trailing
        // slash. Strip those so we don't build "http://http://...:port/v1",
        // which makes URL(string:) return nil and previously CRASHED on the
        // force-unwrap. Never force-unwrap a constructed URL.
        var cleanHost = host.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://"] where cleanHost.lowercased().hasPrefix(scheme) {
            cleanHost = String(cleanHost.dropFirst(scheme.count))
            break
        }
        cleanHost = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if cleanHost.isEmpty { cleanHost = "127.0.0.1" }
        // Bracket a bare IPv6 literal so `URL(string:)` can parse host:port.
        let urlHost = (cleanHost.contains(":") && !cleanHost.hasPrefix("["))
            ? "[\(cleanHost)]" : cleanHost

        let base = "http://\(urlHost):\(port)"
        self.client = OpenAICompatibleClient(
            config: .init(
                baseURL: URL(string: "\(base)/v1")
                    ?? URL(string: "http://127.0.0.1:\(port)/v1")!,
                requestTimeout: requestTimeout
            ))
        self.stateURL = URL(string: "\(base)/state")
            ?? URL(string: "http://127.0.0.1:\(port)/state")!
        self.nodeIDURL = URL(string: "\(base)/node_id")
            ?? URL(string: "http://127.0.0.1:\(port)/node_id")!
        self.modelsURL = URL(string: "\(base)/models")
            ?? URL(string: "http://127.0.0.1:\(port)/models")!
        self.downloadedModelsURL = URL(string: "\(base)/models?status=downloaded")
            ?? URL(string: "http://127.0.0.1:\(port)/models?status=downloaded")!
        let trimmed = pinnedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.pinnedModelID = trimmed.isEmpty ? nil : trimmed
    }

    public func listModels() async throws -> [ModelDescriptor] {
        // Pinned path (production): trust the user's Model ID — return
        // exactly that one descriptor without hitting `/v1/models`.
        if let pinned = pinnedModelID {
            return [ModelDescriptor(id: pinned,
                                    displayName: pinned,
                                    backend: .exo,
                                    supportsTools: true)]
        }
        // Unpinned: try topology's active instance model so the picker is
        // usable without forcing a manual Model ID when EXO already has
        // something loaded. Never fall through to the full 100+ catalog.
        if let topo = try? await fetchTopology(),
           let active = topo.activeModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !active.isEmpty {
            return [ModelDescriptor(id: active,
                                    displayName: active,
                                    backend: .exo,
                                    supportsTools: true)]
        }
        // Nothing pinned and nothing loaded — empty list; Settings can
        // still surface "Model ID required".
        return []
    }

    /// Reachability + catalog readout. Hits `/v1/models` and returns
    /// the list of model IDs EXO recognizes. On most EXO builds this
    /// is the *catalog* (everything EXO could serve, often 100+),
    /// not the loaded model. Used by `discoverLoadedModel()` as a
    /// fallback when topology is unavailable AND the catalog is
    /// short enough to be unambiguous.
    public func discoverAvailableModelIDs() async throws -> [String] {
        let raw = try await client.listModels()
        return raw.map(\.id)
    }


    public nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                let body = await self.encode(request: request)
                let stream = await client.streamChatCompletion(streamID: request.streamID, body: body)
                do {
                    for try await chunk in stream { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    // On disconnect, refresh topology so the user sees which
                    // node dropped. Best-effort — failure here is non-fatal.
                    if let topo = try? await self.fetchTopology() {
                        Diagnostics.warn("EXO stream interrupted; current topology has \(topo.nodes.count) nodes")
                    }
                    continuation.finish(throwing: error)
                }
            }
            // Propagate consumer-side cancellation to the underlying HTTP
            // request (see LMStudioBackend.stream for the rationale).
            continuation.onTermination = { @Sendable reason in
                pump.cancel()
                if case .cancelled = reason {
                    Task { await self.cancel(streamID: request.streamID) }
                }
            }
        }
    }

    public func cancel(streamID: UUID) async { await client.cancel(streamID: streamID) }

    // MARK: - Topology

    public struct ClusterTopology: Codable, Sendable, Equatable {
        public let nodes: [Node]
        /// Coordinator peer id — the node answering `/node_id`.
        public let primary: String?
        /// Model the cluster currently has loaded (first active instance).
        public let activeModel: String?

        public init(nodes: [Node], primary: String?, activeModel: String?) {
            self.nodes = nodes
            self.primary = primary
            self.activeModel = activeModel
        }

        /// Total pooled unified memory across all nodes (GiB) — the capacity
        /// the cluster can dedicate to a sharded model.
        public var pooledMemoryGB: Int { nodes.compactMap(\.memoryGB).reduce(0, +) }

        public struct Node: Codable, Sendable, Equatable {
            public let id: String           // libp2p peer id
            public let name: String?        // friendlyName, e.g. "Max's Mac Studio"
            public let device: String?      // modelId, e.g. "Mac Studio"
            public let chip: String?        // chipId, e.g. "Apple M3 Ultra"
            public let memoryGB: Int?       // ramTotal
            public let memoryFreeGB: Int?   // ramAvailable
            public let gpuUsage: Double?    // 0...1 live load
            public let runsActiveModel: Bool

            public init(id: String, name: String?, device: String?, chip: String?,
                        memoryGB: Int?, memoryFreeGB: Int?, gpuUsage: Double?,
                        runsActiveModel: Bool) {
                self.id = id
                self.name = name
                self.device = device
                self.chip = chip
                self.memoryGB = memoryGB
                self.memoryFreeGB = memoryFreeGB
                self.gpuUsage = gpuUsage
                self.runsActiveModel = runsActiveModel
            }
        }
    }

    /// Fetch and cache the current topology from EXO's `/state` (node
    /// graph + per-node identity/memory/load) and `/node_id` (the
    /// coordinator). The Cluster pane calls this every 12 s while visible.
    public func fetchTopology() async throws -> ClusterTopology {
        let state = try await fetchState()
        // Coordinator is best-effort: if /node_id is missing we still
        // render the cluster, just without the star highlight.
        let primary = try? await fetchNodeID()
        let topo = Self.buildTopology(from: state, primary: primary)
        cachedTopology = topo
        return topo
    }

    private func fetchState() async throws -> EXOStateDTO {
        var req = URLRequest(url: stateURL)
        req.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BackendError.unsupported("EXO /state unavailable — is the cluster running at this host?")
        }
        do {
            return try JSONDecoder().decode(EXOStateDTO.self, from: data)
        } catch {
            throw BackendError.unsupported("EXO /state returned an unexpected shape (\(error.localizedDescription))")
        }
    }

    private func fetchNodeID() async throws -> String {
        var req = URLRequest(url: nodeIDURL)
        req.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: req)
        // /node_id is a bare JSON string: "12D3KooW…"
        return try JSONDecoder().decode(String.self, from: data)
    }

    /// Pure mapping from EXO's wire shape to our view model. Static +
    /// total: every field is optional on the wire, so a partial response
    /// yields a partial-but-valid topology rather than throwing.
    static func buildTopology(from s: EXOStateDTO, primary: String?) -> ClusterTopology {
        // Active model + the set of nodes serving it (first instance).
        let shard = s.instances?.values.first?.values.first?.shardAssignments
        let activeModel = shard?.modelId
        let runningIDs = Set(shard?.nodeToRunner.map { Array($0.keys) } ?? [])

        // Node ordering: prefer the explicit topology list; fall back to
        // whatever identity/memory maps exist.
        let ids = s.topology?.nodes
            ?? s.nodeIdentities.map { Array($0.keys) }
            ?? s.nodeMemory.map { Array($0.keys) }
            ?? []

        let nodes: [ClusterTopology.Node] = ids.map { id in
            let ident = s.nodeIdentities?[id]
            let mem = s.nodeMemory?[id]
            let sys = s.nodeSystem?[id]
            return ClusterTopology.Node(
                id: id,
                name: ident?.friendlyName,
                device: ident?.modelId,
                chip: ident?.chipId,
                memoryGB: mem?.ramTotal.map { gib($0.inBytes) },
                memoryFreeGB: mem?.ramAvailable.map { gib($0.inBytes) },
                gpuUsage: sys?.gpuUsage,
                runsActiveModel: runningIDs.contains(id)
            )
        }
        // Coordinator first for a stable, readable layout.
        .sorted { ($0.id == primary ? 0 : 1) < ($1.id == primary ? 0 : 1) }

        return ClusterTopology(nodes: nodes, primary: primary, activeModel: activeModel)
    }

    /// Apple reports unified memory in binary GB (GiB). 549_755_813_888 → 512.
    private static func gib(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_073_741_824).rounded())
    }

    public var lastKnownTopology: ClusterTopology? { cachedTopology }

    // MARK: - Catalog

    /// Fetch EXO's full model catalog (GET /models) and merge in downloaded
    /// status (GET /models?status=downloaded). The downloaded query is
    /// best-effort — if it fails we still return the catalog, just with
    /// everything marked not-downloaded.
    public func fetchCatalog() async throws -> [EXOCatalogModel] {
        let all = try await getModels(downloadedOnly: false)
        let downloadedIDs = Set(((try? await getModels(downloadedOnly: true)) ?? []).map(\.id))
        return all.map { dto in
            EXOCatalogModel(
                id: dto.id,
                name: dto.name ?? dto.id,
                family: dto.family,
                quantization: dto.quantization,
                baseModel: dto.baseModel,
                contextLength: dto.contextLength,
                capabilities: dto.capabilities ?? [],
                storageMB: dto.storageSizeMegabytes,
                isCustom: dto.isCustom ?? false,
                downloaded: downloadedIDs.contains(dto.id)
            )
        }
    }

    private func getModels(downloadedOnly: Bool) async throws -> [EXOModelDTO] {
        var req = URLRequest(url: downloadedOnly ? downloadedModelsURL : modelsURL)
        req.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BackendError.unsupported("EXO /models unavailable — is the cluster running at this host?")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EXOModelsResponseDTO.self, from: data).data
    }

    // MARK: - Encoding

    private func encode(request: ChatRequest) -> ChatCompletionRequestBody {
        let wireMessages = ChatCompletionRequestBody.assembledWireMessages(
            from: request.messages, emptyTextAsEmptyString: false)
        let wireTools: [ChatCompletionRequestBody.WireTool]? = request.tools.isEmpty ? nil : request.tools.map {
            .init(function: .init(name: $0.name, description: $0.description, parameters: $0.parameters))
        }
        // Always send the pinned Model ID when set — EXO is strict
        // about the model field (404s any unrecognized ID), but
        // upstream callers (LocalAPIServer forwarding Xcode 16
        // Intelligence requests, future Claude Code routing, etc.)
        // may legitimately pass their own model name. We translate
        // here so EXO consistently sees the loaded model, no matter
        // what the inbound request asked for. llama.cpp via
        // llama-server is permissive on this and didn't need the
        // translation — that's why llama.cpp "just worked" and EXO
        // didn't.
        let outboundModel = pinnedModelID ?? request.model.id
        var body = ChatCompletionRequestBody(
            model: outboundModel,
            messages: wireMessages,
            tools: wireTools,
            sampling: request.sampling,
            stream: true
        )
        if let thinking = request.thinking {
            ThinkingModelScanner.applyThinking(
                to: &body.extraBody,
                capability: thinking.capability,
                effort: thinking.effort
            )
        }
        return body
    }
}

// MARK: - EXO /state wire DTOs

/// Decodable subset of EXO's `GET /state` payload — only the fields the
/// Cluster pane needs; the rest of the (large) response is ignored. Every
/// field is optional so a partial or version-drifted response still decodes
/// into a usable (if sparser) topology instead of throwing.
struct EXOStateDTO: Decodable {
    struct Bytes: Decodable { let inBytes: Int64 }

    struct Identity: Decodable {
        let modelId: String?       // "Mac Studio"
        let chipId: String?        // "Apple M3 Ultra"
        let friendlyName: String?  // "Max's Mac Studio"
    }
    struct Memory: Decodable {
        let ramTotal: Bytes?
        let ramAvailable: Bytes?
    }
    struct System: Decodable {
        let gpuUsage: Double?       // 0...1
        let temp: Double?
        let sysPower: Double?
    }
    struct Topology: Decodable {
        let nodes: [String]?       // ordered peer ids
    }
    struct InstanceBody: Decodable {
        struct Shard: Decodable {
            let modelId: String?
            let nodeToRunner: [String: String]?   // peerID → runnerID
        }
        let shardAssignments: Shard?
    }

    let topology: Topology?
    let nodeIdentities: [String: Identity]?
    let nodeMemory: [String: Memory]?
    let nodeSystem: [String: System]?
    /// instanceID → (instanceTypeName → body). EXO wraps each instance in a
    /// single-key object keyed by its variant name ("MlxRingInstance").
    let instances: [String: [String: InstanceBody]]?
}
