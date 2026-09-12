#if (os(macOS) || os(iOS) || os(Linux)) && (arch(x86_64) || arch(arm64))

    #if canImport(Darwin)
        import Darwin
    #elseif canImport(Musl)
        import Musl
    #elseif canImport(Glibc)
        import Glibc
    #endif

    /// A wasm32 linear memory whose address space is reserved once and committed as it grows.
    ///
    /// WebAssembly pages are multiples of every supported host page size. Newly committed
    /// anonymous pages are demand-zero, so growth neither copies nor eagerly clears the
    /// existing linear memory.
    struct ReservedLinearMemory {
        private(set) var baseAddress: UnsafeMutableRawPointer
        private(set) var committedSize: Int
        let reservationSize: Int

        init(committedSize: Int, reservationSize: Int) throws {
            precondition(committedSize >= 0)
            precondition(reservationSize >= committedSize)
            precondition(reservationSize > 0)

            #if os(Linux)
                let anonymousFlag = MAP_ANONYMOUS
            #else
                let anonymousFlag = MAP_ANON
            #endif
            // WasmKit's upstream mprotect-backed strategy is deliberately limited to
            // macOS and Linux. On iOS, keep the stable lazy reservation readable and
            // writable while the interpreter enforces the logical committed bound.
            // Anonymous pages remain demand-zero and consume physical memory only when
            // touched, without relying on unsupported incremental mprotect behavior.
            #if os(iOS)
                let initialProtection = PROT_READ | PROT_WRITE
            #else
                let initialProtection = PROT_NONE
            #endif
            let mapped = mmap(
                nil,
                reservationSize,
                initialProtection,
                MAP_PRIVATE | anonymousFlag,
                -1,
                0
            )
            guard mapped != MAP_FAILED, let mapped else {
                throw Trap(.initialMemorySizeExceedsLimit(byteSize: committedSize))
            }

            baseAddress = mapped
            self.committedSize = 0
            self.reservationSize = reservationSize

            do {
                try grow(to: committedSize)
            } catch {
                munmap(baseAddress, reservationSize)
                throw error
            }
        }

        mutating func grow(to newCommittedSize: Int) throws {
            precondition(newCommittedSize >= committedSize)
            guard newCommittedSize <= reservationSize else {
                throw Trap(.memoryOutOfBounds)
            }

            let delta = newCommittedSize - committedSize
            guard delta > 0 else { return }
            #if os(iOS)
                committedSize = newCommittedSize
                return
            #else
            let start = baseAddress.advanced(by: committedSize)
            guard mprotect(start, delta, PROT_READ | PROT_WRITE) == 0 else {
                throw Trap(.memoryOutOfBounds)
            }
            committedSize = newCommittedSize
            #endif
        }

        func makeBufferPointer() -> UnsafeMutableBufferPointer<UInt8> {
            UnsafeMutableBufferPointer(
                start: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: committedSize
            )
        }

        func deallocate() {
            munmap(baseAddress, reservationSize)
        }
    }

#endif
