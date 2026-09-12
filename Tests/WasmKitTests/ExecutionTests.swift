import Testing
import WAT

@testable import WasmKit

@Suite
struct ExecutionTests {

    @Test
    func dropWithRelinkingOptimization() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (func (export "_start") (result i32) (local $x i32)
                        (i32.const 42)
                        (i32.const 0)
                        (i32.eqz)
                        (drop)
                        (local.set $x)
                        (local.get $x)
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try #require(instance.exports[function: "_start"])
        let results = try _start()
        #expect(results == [.i32(42)])
    }

    @Test
    func updateCurrentMemoryCacheOnGrow() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (memory 0)
                    (func (export "_start") (result i32)
                        (drop (memory.grow (i32.const 1)))
                        (i32.store (i32.const 1) (i32.const 42))
                        (i32.load (i32.const 1))
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let _start = try #require(instance.exports[function: "_start"])
        let results = try _start()
        #expect(results == [.i32(42)])
    }

    @Test
    func memoryGrowKeepsReservedStorageAndZeroesNewPages() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (memory (export "memory") 1 4)
                    (func (export "grow") (param i32) (result i32)
                        (memory.grow (local.get 0))
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let memory = try #require(instance.exports[memory: "memory"])
        let grow = try #require(instance.exports[function: "grow"])

        let originalAddress = memory.withUnsafeMutableBufferPointer(offset: 0, count: 1) { bytes in
            bytes[0] = 0xA5
            return UInt(bitPattern: bytes.baseAddress!)
        }

        #expect(try grow([.i32(2)]) == [.i32(1)])

        memory.withUnsafeBufferPointer(offset: 0, count: 3 * MemoryEntity.pageSize) { bytes in
            #expect(UInt(bitPattern: bytes.baseAddress!) == originalAddress)
            #expect(bytes[0] == 0xA5)
            #expect(bytes[MemoryEntity.pageSize] == 0)
            #expect(bytes[3 * MemoryEntity.pageSize - 1] == 0)
        }
        #expect(try grow([.i32(2)]) == [.i32(UInt32.max)])
    }

    @Test
    func memoryGrowAcrossThirtyTwoPageBoundaryKeepsStorageAndZeroesNewPage() throws {
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (memory (export "memory") 30 64)
                    (func (export "grow") (param i32) (result i32)
                        (memory.grow (local.get 0))
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let memory = try #require(instance.exports[memory: "memory"])
        let grow = try #require(instance.exports[function: "grow"])

        let originalAddress = memory.withUnsafeMutableBufferPointer(offset: 0, count: 1) { bytes in
            bytes[0] = 0xA5
            return UInt(bitPattern: bytes.baseAddress!)
        }
        #expect(try grow([.i32(2)]) == [.i32(30)])
        #expect(try grow([.i32(1)]) == [.i32(32)])

        let lastByteOffset = UInt(33 * MemoryEntity.pageSize - 1)
        memory.withUnsafeMutableBufferPointer(offset: lastByteOffset, count: 1) { bytes in
            #expect(UInt(bitPattern: bytes.baseAddress!) == originalAddress + lastByteOffset)
            #expect(bytes[0] == 0)
            bytes[0] = 0x5A
            #expect(bytes[0] == 0x5A)
        }
        memory.withUnsafeBufferPointer(offset: 0, count: 1) { bytes in
            #expect(UInt(bitPattern: bytes.baseAddress!) == originalAddress)
            #expect(bytes[0] == 0xA5)
        }
    }

    @Test
    func largeMemoryGrowKeepsReservedStorageLazy() throws {
        let targetPageCount: UInt32 = 32_327
        let module = try parseWasm(
            bytes: wat2wasm(
                """
                (module
                    (memory (export "memory") 28 32768)
                    (func (export "grow") (param i32) (result i32)
                        (memory.grow (local.get 0))
                    )
                )
                """
            )
        )
        let engine = Engine()
        let store = Store(engine: engine)
        let instance = try module.instantiate(store: store)
        let memory = try #require(instance.exports[memory: "memory"])
        let grow = try #require(instance.exports[function: "grow"])

        let originalAddress = memory.withUnsafeBufferPointer(offset: 0, count: 1) {
            UInt(bitPattern: $0.baseAddress!)
        }
        #expect(try grow([.i32(targetPageCount - 28)]) == [.i32(28)])

        let finalByteOffset = UInt(targetPageCount) * UInt(MemoryEntity.pageSize) - 1
        memory.withUnsafeMutableBufferPointer(offset: finalByteOffset, count: 1) { bytes in
            #expect(UInt(bitPattern: bytes.baseAddress!) == originalAddress + UInt(finalByteOffset))
            #expect(bytes[0] == 0)
            bytes[0] = 0x5A
            #expect(bytes[0] == 0x5A)
        }
    }

    func expectTrap(_ wat: String, assertTrap: (Trap) throws -> Void) throws {
        let module = try parseWasm(
            bytes: wat2wasm(wat, options: EncodeOptions(nameSection: true))
        )

        let engine = Engine()
        let store = Store(engine: engine)
        var imports = Imports()
        for importEntry in module.imports {
            guard case .function(let type) = importEntry.descriptor else { continue }
            let function = try Function(
                store: store,
                type: module.resolveFunctionType(type),
                body: { _, _ in
                    return []
                }
            )
            imports.define(importEntry, .function(function))
        }
        let instance = try module.instantiate(store: store, imports: imports)
        let _start = try #require(instance.exports[function: "_start"])

        let trap: Trap
        do {
            let _ = try _start()
            #expect((false), "Expected trap")
            return
        } catch let _trap as Trap {
            trap = _trap
        } catch {
            #expect((false), "Expected trap: \(error)")
            return
        }
        try assertTrap(trap)
    }

    @Test
    func backtraceBasic() throws {
        try expectTrap(
            """
            (module
                (func $foo
                    unreachable
                )
                (func $bar
                    (call $foo)
                )
                (func (export "_start")
                    (call $bar)
                )
            )
            """
        ) { trap in
            #expect(
                trap.backtrace?.symbols.compactMap(\.name) == [
                    "foo",
                    "bar",
                    "_start",
                ])
        }
    }

    @Test
    func backtraceWithImports() throws {
        try expectTrap(
            """
            (module
                (func (import "env" "bar"))
                (func
                    unreachable
                )
                (func $bar
                    (call 1)
                )
                (func (export "_start")
                    (call $bar)
                )
            )
            """
        ) { trap in
            #expect(
                trap.backtrace?.symbols.compactMap(\.name) == [
                    "wasm function[1]",
                    "bar",
                    "_start",
                ])
        }
    }
}
