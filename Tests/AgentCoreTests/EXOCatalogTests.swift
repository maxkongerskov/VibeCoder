//
//  EXOCatalogTests.swift
//  AgentCoreTests
//
//  Locks the EXO catalog decode (snake_case /models), the pooled-memory
//  fit math, and the /state topology decode against the real wire shapes
//  captured from a live Mac Studio + MacBook Pro cluster.
//

import XCTest
@testable import AgentCore

final class EXOCatalogTests: XCTestCase {

    // MARK: - /models decode (snake_case envelope)

    private let modelsJSON = """
    {
      "data": [
        {
          "id": "mlx-community/MiniMax-M2.7-4bit",
          "object": "model",
          "name": "MiniMax-M2.7-4bit",
          "context_length": 196608,
          "storage_size_megabytes": 122721,
          "supports_tensor": true,
          "is_custom": false,
          "family": "minimax",
          "quantization": "4bit",
          "base_model": "MiniMax M2.7",
          "capabilities": ["text", "thinking"]
        }
      ]
    }
    """

    func testDecodesModelsEnvelopeWithSnakeCase() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try decoder.decode(EXOModelsResponseDTO.self,
                                      from: Data(modelsJSON.utf8))
        XCTAssertEqual(resp.data.count, 1)
        let m = resp.data[0]
        XCTAssertEqual(m.id, "mlx-community/MiniMax-M2.7-4bit")
        XCTAssertEqual(m.storageSizeMegabytes, 122721)
        XCTAssertEqual(m.baseModel, "MiniMax M2.7")
        XCTAssertEqual(m.contextLength, 196608)
        XCTAssertEqual(m.isCustom, false)
        XCTAssertEqual(m.capabilities, ["text", "thinking"])
    }

    func testCatalogModelStorageGBConvertsFromMiB() {
        let m = EXOCatalogModel(id: "x", name: "x", family: nil, quantization: nil,
                                baseModel: nil, contextLength: nil, capabilities: [],
                                storageMB: 122721, isCustom: false, downloaded: false)
        // 122721 MiB / 1024 = 119.8 GiB
        XCTAssertEqual(m.storageGB ?? 0, 119.8, accuracy: 0.1)
    }

    func testShortNameStripsOrgPrefix() {
        let m = EXOCatalogModel(id: "mlx-community/MiniMax-M2.7-4bit", name: "n",
                                family: nil, quantization: nil, baseModel: nil,
                                contextLength: nil, capabilities: [], storageMB: nil,
                                isCustom: false, downloaded: false)
        XCTAssertEqual(m.shortName, "MiniMax-M2.7-4bit")
    }

    // MARK: - Fit math

    func testFitFitsWhenComfortablyUnderPool() {
        // MiniMax-M2.7-4bit (~120 GiB) on a 544 GiB pool.
        XCTAssertEqual(ClusterFit.evaluate(modelGB: 119.8, pooledGB: 544), .fits)
    }

    func testFitExceedsWhenLargerThanPool() {
        // Qwen3-Coder-480B 8-bit (~566 GiB) on a 544 GiB pool.
        XCTAssertEqual(ClusterFit.evaluate(modelGB: 566, pooledGB: 544), .exceeds)
    }

    func testFitTightInTopTenPercentOfPool() {
        // 530 GiB on 544 GiB pool: above 90% (489.6) but still fits.
        XCTAssertEqual(ClusterFit.evaluate(modelGB: 530, pooledGB: 544), .tight)
    }

    func testFitUnknownWhenSizeOrPoolMissing() {
        XCTAssertEqual(ClusterFit.evaluate(modelGB: nil, pooledGB: 544), .unknown)
        XCTAssertEqual(ClusterFit.evaluate(modelGB: 100, pooledGB: 0), .unknown)
    }

    // MARK: - /state topology decode (camelCase) + pooled memory

    private let stateJSON = """
    {
      "topology": { "nodes": ["B", "A"] },
      "nodeIdentities": {
        "A": { "modelId": "Mac Studio", "chipId": "Apple M3 Ultra", "friendlyName": "Max's Mac Studio" },
        "B": { "modelId": "MacBook Pro", "chipId": "Apple M1 Max", "friendlyName": "Max's MacBook Pro" }
      },
      "nodeMemory": {
        "A": { "ramTotal": { "inBytes": 549755813888 }, "ramAvailable": { "inBytes": 470685827072 } },
        "B": { "ramTotal": { "inBytes": 34359738368 }, "ramAvailable": { "inBytes": 22386278400 } }
      },
      "nodeSystem": {
        "A": { "gpuUsage": 0.31 },
        "B": { "gpuUsage": 0.18 }
      },
      "instances": {
        "inst1": { "MlxRingInstance": { "shardAssignments": {
          "modelId": "mlx-community/MiniMax-M2.7-8bit",
          "nodeToRunner": { "A": "r1", "B": "r2" }
        } } }
      }
    }
    """

    func testBuildsTopologyFromRealStateShape() throws {
        let state = try JSONDecoder().decode(EXOStateDTO.self, from: Data(stateJSON.utf8))
        let topo = EXOBackend.buildTopology(from: state, primary: "A")

        XCTAssertEqual(topo.nodes.count, 2)
        XCTAssertEqual(topo.primary, "A")
        XCTAssertEqual(topo.activeModel, "mlx-community/MiniMax-M2.7-8bit")

        // Coordinator sorted first even though topology.nodes listed B first.
        let coordinator = topo.nodes[0]
        XCTAssertEqual(coordinator.id, "A")
        XCTAssertEqual(coordinator.name, "Max's Mac Studio")
        XCTAssertEqual(coordinator.chip, "Apple M3 Ultra")
        XCTAssertEqual(coordinator.memoryGB, 512)       // 549755813888 / 1024^3
        XCTAssertTrue(coordinator.runsActiveModel)
        XCTAssertEqual(coordinator.gpuUsage ?? 0, 0.31, accuracy: 0.001)

        let worker = topo.nodes[1]
        XCTAssertEqual(worker.id, "B")
        XCTAssertEqual(worker.memoryGB, 32)             // 34359738368 / 1024^3
        XCTAssertTrue(worker.runsActiveModel)
    }

    func testPooledMemorySumsNodes() throws {
        let state = try JSONDecoder().decode(EXOStateDTO.self, from: Data(stateJSON.utf8))
        let topo = EXOBackend.buildTopology(from: state, primary: "A")
        XCTAssertEqual(topo.pooledMemoryGB, 544)        // 512 + 32
    }

    func testTopologyUnavailableModelFitOnRealCluster() throws {
        let state = try JSONDecoder().decode(EXOStateDTO.self, from: Data(stateJSON.utf8))
        let pooled = EXOBackend.buildTopology(from: state, primary: "A").pooledMemoryGB
        // The 8-bit 480B coder won't fit 544 GiB; its 4-bit sibling will.
        XCTAssertEqual(ClusterFit.evaluate(modelGB: 566, pooledGB: pooled), .exceeds)
        XCTAssertEqual(ClusterFit.evaluate(modelGB: 283, pooledGB: pooled), .fits)
    }
}
