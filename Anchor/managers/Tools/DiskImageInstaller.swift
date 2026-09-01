/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
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

import AppKit
import Combine
import Defaults
import DiskArbitration
import Foundation

// MARK: - Pure decision

/// Works out what, if anything, a newly mounted volume is offering to install.
///
/// Pure, because every interesting case is a shape of disk image rather than a
/// timing problem: a DMG with two apps, one with an `Applications` symlink
/// beside the app, one holding an installer package, one that is simply a USB
/// stick with an app on it. Reproducing those means building disk images;
/// deciding about them is a function over filenames.
enum DiskImageContents {

    struct Candidate: Equatable {
        /// The app bundle to install.
        let appPath: String
        /// Its filename without the extension, for the prompt.
        var displayName: String {
            (appPath as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
        }
    }

    enum Outcome: Equatable {
        /// Exactly one app, and it is not already the running one.
        case offer(Candidate)
        /// Several apps — a suite. Offering to install "the" app would be a
        /// guess, and picking the wrong one silently is worse than staying
        /// quiet, so this asks rather than choosing.
        case ambiguous([Candidate])
        /// Nothing to do.
        case ignore
    }

    /// What to do about a volume whose root contains `entries`.
    ///
    /// `installedBundleIDs` is what is already in `/Applications`, so a DMG for
    /// something already installed can be treated as an update rather than a
    /// first install. `isSymlink` reports which entries are links, because the
    /// `Applications` alias is a symlink to `/Applications` and copying *that*
    /// would be catastrophic.
    static func evaluate(
        entries: [String],
        volumePath: String,
        isSymlink: (String) -> Bool = { _ in false }
    ) -> Outcome {
        // Two filters, and only two, because a name list of things to skip
        // turned out to be dead code: `Applications`, `.background`,
        // `.DS_Store` and every other standard DMG entry already fail the
        // `.app` suffix check. It was removed rather than left in place —
        // a negative-control run showed deleting it changed no behaviour,
        // which is the definition of a guard that is not guarding anything.
        //
        // The suffix must be a suffix, not a substring: `Thing.application`
        // is not an app bundle. The symlink check is the one that matters —
        // the drag-here alias IS named `Something.app` on some images, and
        // copying a symlink to /Applications over /Applications would be
        // catastrophic.
        let apps = entries
            .filter { $0.hasSuffix(".app") }
            .filter { !isSymlink($0) }
            .sorted()

        let candidates = apps.map {
            Candidate(appPath: (volumePath as NSString).appendingPathComponent($0))
        }

        switch candidates.count {
        case 0:  return .ignore
        case 1:  return .offer(candidates[0])
        default: return .ambiguous(candidates)
        }
    }

    /// Buses that mean physical media rather than a disk image.
    ///
    /// From `DADiskDescriptionDeviceProtocol`. A mounted DMG reports
    /// `"Virtual Interface"` — which `diskutil` displays, confusingly, as
    /// "Disk Image".
    private static let physicalProtocols: Set<String> = [
        "USB", "SATA", "Thunderbolt", "FireWire", "Secure Digital",
        "Apple Fabric", "PCI-Express", "SCSI", "ATA",
    ]

    /// Whether a mounted volume is a disk image rather than the startup disk,
    /// a USB stick or a network share.
    ///
    /// ## The values here were measured, not assumed
    ///
    /// The first version of this tested `isRemovable && !isInternal`, on the
    /// reasonable-sounding belief that a disk image is not "internal". It is:
    /// a real mounted DMG on this machine reports
    /// **`removable=true, internal=true, ejectable=true, rootFS=false`**,
    /// so that test returned false for every disk image and the feature could
    /// never once have fired. Nothing but mounting an actual image caught it —
    /// the unit tests happily encoded the same wrong assumption.
    ///
    /// | | removable | internal | ejectable | rootFS |
    /// |---|---|---|---|---|
    /// | mounted DMG | true | true | true | false |
    /// | startup disk | false | true | false | true |
    ///
    /// ## Why the protocol check is a refinement and not the gate
    ///
    /// `deviceProtocol` distinguishes a DMG from a USB stick exactly, but it
    /// is an undocumented string. It is therefore used only to *reject*
    /// known-physical buses. If Apple renames the virtual one, this degrades to
    /// occasionally offering on a USB stick — mildly annoying — rather than
    /// back to never firing at all, which is the failure that just happened.
    static func isDiskImage(
        isRemovable: Bool, isEjectable: Bool, isRootFileSystem: Bool,
        isNetwork: Bool, deviceProtocol: String?
    ) -> Bool {
        guard isRemovable, isEjectable, !isRootFileSystem, !isNetwork else { return false }
        if let deviceProtocol, physicalProtocols.contains(deviceProtocol) { return false }
        return true
    }
}

// MARK: - Manager

/// Offers to copy an app out of a mounted disk image into `/Applications`.
///
/// ## Nothing is copied without the user saying so
///
/// The manager only ever *asks*. Copying an application into `/Applications`
/// is not reversible from the user's point of view — it can overwrite a version
/// they were deliberately keeping — so the copy, the replacement of any
/// existing copy, and the eject all happen behind an explicit confirmation.
///
/// ## Cost
///
/// One `NSWorkspace` mount notification subscription while enabled. No polling.
@MainActor
final class DiskImageInstaller: ObservableObject {
    static let shared = DiskImageInstaller()

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didMountNotification)
            .sink { [weak self] note in
                Task { @MainActor in self?.volumeMounted(note) }
            }
            .store(in: &cancellables)
    }

    /// The bus a volume is attached to, from DiskArbitration. Nil when it
    /// cannot be determined, which the caller treats as "not disqualifying".
    private static func deviceProtocol(for url: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return description[kDADiskDescriptionDeviceProtocolKey as String] as? String
    }

    private func volumeMounted(_ note: Notification) {
        guard Defaults[.enableDiskImageInstaller] else { return }
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }

        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsRootFileSystemKey, .volumeIsLocalKey]),
            DiskImageContents.isDiskImage(
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isRootFileSystem: values.volumeIsRootFileSystem ?? true,
                isNetwork: !(values.volumeIsLocal ?? true),
                deviceProtocol: Self.deviceProtocol(for: url))
        else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return }

        let outcome = DiskImageContents.evaluate(
            entries: entries,
            volumePath: url.path,
            isSymlink: { name in
                let path = (url.path as NSString).appendingPathComponent(name)
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            })

        switch outcome {
        case .offer(let candidate):
            promptToInstall(candidate, volume: url)
        case .ambiguous, .ignore:
            // Deliberately silent. A suite with four apps is for the user to
            // drag themselves; guessing which one they meant is worse than
            // not offering.
            break
        }
    }

    private func promptToInstall(_ candidate: DiskImageContents.Candidate, volume: URL) {
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent((candidate.appPath as NSString).lastPathComponent)
        let exists = FileManager.default.fileExists(atPath: destination.path)

        let alert = NSAlert()
        alert.messageText = exists
            ? "Replace \(candidate.displayName) in Applications?"
            : "Install \(candidate.displayName)?"
        alert.informativeText = exists
            ? "A copy is already in Applications. The existing one is moved to the Trash, not deleted, so you can put it back."
            : "Copies \(candidate.displayName) to Applications and ejects the disk image."
        alert.addButton(withTitle: exists ? "Replace" : "Install")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(candidate, from: volume, to: destination, replacing: exists)
    }

    private func install(_ candidate: DiskImageContents.Candidate, from volume: URL,
                         to destination: URL, replacing: Bool) {
        let source = URL(fileURLWithPath: candidate.appPath)
        do {
            if replacing {
                // Trash, never remove. An app the user was deliberately keeping
                // at an old version must be recoverable in one drag.
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not install \(candidate.displayName)"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Eject only after a successful copy — ejecting on failure would take
        // away the disk image the user now needs to install by hand.
        try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        NSLog("DiskImageInstaller: installed \(candidate.displayName)")
    }
}
