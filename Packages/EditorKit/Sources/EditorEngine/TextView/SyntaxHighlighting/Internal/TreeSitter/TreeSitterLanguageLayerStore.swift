import Foundation
import os

/// Threadsafe map of tree-sitter language layers keyed by language pointer.
///
/// `OSAllocatedUnfairLock` is used in place of `DispatchSemaphore` because
/// a semaphore can't tell the kernel which thread holds it, so a
/// user-interactive thread waiting behind a default-QoS thread becomes a
/// priority inversion (Xcode "Hang Risk"). The unfair lock boosts the
/// holder's QoS to match the highest waiter — exactly what we want here,
/// since the critical sections are tiny dictionary mutations.
///
/// The non-generic `OSAllocatedUnfairLock` variant is used so the keys
/// (which are non-Sendable `UnsafeRawPointer`s) don't have to cross a
/// `@Sendable` closure boundary.
final class TreeSitterLanguageLayerStore {
    var allIDs: [UnsafeRawPointer] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.keys)
    }

    var allLayers: [TreeSitterLanguageLayer] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.values)
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return store.isEmpty
    }

    private var store: [UnsafeRawPointer: TreeSitterLanguageLayer] = [:]
    private let lock = OSAllocatedUnfairLock()

    func storeLayer(_ layer: TreeSitterLanguageLayer, forKey key: UnsafeRawPointer) {
        lock.lock(); defer { lock.unlock() }
        store[key] = layer
    }

    func layer(forKey key: UnsafeRawPointer) -> TreeSitterLanguageLayer? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func removeLayer(forKey key: UnsafeRawPointer) {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}
