/*
 * Anchor — test stub for the `Defaults` SPM package.
 *
 * Several models conform to `Defaults.Serializable` purely so the value can be
 * stored in preferences. The conformance carries nothing that affects the
 * logic under test, and the real package cannot be resolved from a bare
 * `swiftc` invocation.
 *
 * **This is compiled into a module literally named `Defaults`**, not merely
 * included as a file — `import Defaults` needs a module, which is why the
 * LoggerStub approach (a type in the same module) does not work here. The
 * runner emits it with `-emit-module -module-name Defaults` first.
 *
 * Keep this minimal. Needing real preference storage in a test would mean the
 * code under test is not pure enough to test this way.
 */

import Foundation

/// Marker only. The real protocol's bridging requirements are satisfied by the
/// conforming types through `Codable`, and none of them affect formatting or
/// arithmetic.
public protocol Serializable {}

/// The real package exposes this as a generic key type. Nothing under test
/// reads or writes preferences, so it only has to exist for declarations that
/// mention it to compile.
public struct Key<Value> {
    public let name: String
    public let defaultValue: Value
    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}
