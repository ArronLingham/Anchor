#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/main.swift" <<'SWIFT'
import Foundation

var checks = 0
func expect(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    checks += 1
}

expect(LauncherPaging.landingPage(showCategories: true, startOnCategories: true) == -1, "categories landing page")
expect(LauncherPaging.landingPage(showCategories: true, startOnCategories: false) == 0, "apps landing page")
expect(LauncherPaging.landingPage(showCategories: false, startOnCategories: true) == 0, "hidden categories fall back to apps")
expect(Array(LauncherPaging.pageIDs(appPageCount: 3, showCategories: true)) == [-1, 0, 1, 2], "categories precede the app pages")
expect(Array(LauncherPaging.pageIDs(appPageCount: 3, showCategories: false)) == [0, 1, 2], "hiding categories preserves app page identity")
expect(Array(LauncherPaging.pageIDs(appPageCount: 0, showCategories: true)) == [-1, 0], "empty index retains the two initial targets")
expect(Array(LauncherPaging.pageIDs(appPageCount: 0, showCategories: false)) == [0], "empty index with hidden categories retains app target")

let perPage = 28
for folders in [0, 1, 3, 27, 28, 29, 56, 135] {
    for apps in [0, 1, 10, 40, 116, 400] {
        let count = LauncherPaging.pageCount(folderCount: folders, appCount: apps, perPage: perPage)
        let slots = Array(repeating: Int?.none, count: folders) + (0..<apps).map(Optional.some)
        for page in LauncherPaging.pageIDs(appPageCount: count, showCategories: true) {
            let selections = LauncherPaging.selections(onPage: page, folderCount: folders, perPage: perPage, appCount: apps)
            let expected = page < 0 ? [] : slots.dropFirst(page * perPage).prefix(perPage).compactMap { $0 }
            expect(Array(selections) == expected, "selections match grid slots with \(folders) folders, \(apps) apps, on page \(page)")
            for selection in selections {
                let appPage = LauncherPaging.page(forSelection: selection, folderCount: folders, perPage: perPage)
                expect(appPage == page, "app selection maps back to its exact page")
            }
        }
    }
}

expect(LauncherPaging.page(forSelection: 0, folderCount: 29, perPage: perPage) == 1, "first app can follow a folder-only page")
expect(LauncherPaging.selections(onPage: 1, folderCount: 3, perPage: perPage, appCount: 116).first == 25, "folder slots offset page selection")
expect(LauncherPaging.selections(onPage: 4, folderCount: 3, perPage: perPage, appCount: 116) == 109..<116, "partial last page clips selection")
expect(LauncherPaging.selections(onPage: 0, folderCount: 0, perPage: 0, appCount: 10).isEmpty, "invalid page size has no selections")
expect(LauncherPaging.pageCount(folderCount: 3, appCount: 3, perPage: 0) == 0, "invalid page size has no app pages")
expect(LauncherPaging.pageCount(folderCount: 0, appCount: 0, perPage: perPage) == 0, "empty grid has no populated pages")
expect(LauncherPaging.pageCount(folderCount: 28, appCount: 1, perPage: perPage) == 2, "folders occupy app page slots")
print("\(checks) Launchpad paging checks passed")
SWIFT

swiftc -O Anchor/Managers/Launcher/LauncherPaging.swift "$work/main.swift" -o "$work/paging"
"$work/paging"
