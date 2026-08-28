/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Darwin
import Foundation

/// Resolves a PID to its `p_comm` short executable name via sysctl.
enum ProcessNameLookup {
    /// Returns the short executable name for a PID, or nil when the PID is
    /// invalid or the lookup fails.
    static func name(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }

        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else {
            return nil
        }

        // `sysctl` zeroes `size` when the PID is not found.
        guard size > 0 else { return nil }

        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { tuplePtr -> String in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuplePtr.pointee)) { cStr in
                String(cString: cStr)
            }
        }

        return name.isEmpty ? nil : name
    }
}
