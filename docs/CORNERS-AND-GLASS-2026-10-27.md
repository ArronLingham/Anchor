# Concentric corners and native Liquid Glass

## Research and platform

- Apple: [ConcentricRectangle](https://developer.apple.com/documentation/swiftui/concentricrectangle), [RoundedRectangularShape](https://developer.apple.com/documentation/swiftui/roundedrectangularshape), and [custom Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
- Expo: [expo-glass-effect](https://docs.expo.dev/versions/latest/sdk/glass-effect/) wraps iOS UIVisualEffectView. It provides Liquid Glass on iOS 26 and falls back to an ordinary view on unsupported platforms. Anchor is native Swift/macOS, so the implementation uses Apple's macOS SwiftUI APIs.
- Anchor already targets macOS 26. The embedded AnchorUtilities package now declares the same minimum instead of macOS 14.

## Corner policy

`AnchorCorners.rectangle` returns Apple's actual ConcentricRectangle, preserving native container resolution rather than approximating the shape with a custom path. Uniform corners use the existing component radius as a minimum, so controls remain rounded away from a container's edges. Full padded cards establish a container boundary; small controls inherit it instead of overriding it with their own boundary.

The migration covers native screens and utility views: settings, Dashboard, Launchpad, clipboard, shelf, calendar, timers, notch content, music, lock-screen panels, overlays, onboarding, and tool editors. Shared native cards, utility SettingsCard/panel cards, and notch control surfaces establish container geometry. Fills, clipping, outlines, and selection surfaces use the shared policy.

ConcentricRectangle does not conform to InsettableShape. The shared border helper clips a double-width stroke to the resolved shape, keeping the visible border inside its fill. It supports solid and dashed outlines. Decorative multi-rim player borders resolve inside a padded concentric shape.

Intentional fixed geometry remains: the concave physical-notch outline and its input path, circles and capsules, explicitly scaled artwork/app-icon masks, tiny chart/event/battery marks, screenshot-selection coordinates, uneven terminal corners, and AppKit/Core Animation drawing. Those are not ordinary nested rounded SwiftUI surfaces. No polling or geometry measurement loop was added.

## Liquid Glass policy

Every existing SwiftUI Liquid Glass call now goes through `anchorLiquidGlass`, which invokes the public system renderer. Ordinary shaded content cards and selected non-glass styles remain shaded; this is a renderer migration, not a forced material preference change. Window-wide GlassEffectContainer grouping was deliberately excluded: existing panels use separate background backplates, and live testing demonstrated that grouping those backplates with uncaptured foreground siblings blurs their text. Apple's grouping guidance applies to appropriately composed peer controls, not an indiscriminate wrapper around a whole window.

The old LiquidGlassBackground NSViewRepresentable, private variant setter, backdrop-layer inspection, and KVO callbacks were replaced by a SwiftUI view. Its content remains in the parent's view tree. Saved preset IDs 0–19 are retained: 0–9 use public Clear glass and 10–19 use public Regular glass, each with ten tint strengths. Preset labels show the actual native finish. The private presets' exact appearances are not preserved, because those undocumented variants have no public equivalents.

Reduce Transparency substitutes an opaque light/dark surface in the same shape and switches the system effect to Glass.identity. Increased Contrast adds a visible outline. The foreground stays in one structural branch, so toggling accessibility preferences does not replace a text field's structural identity. Timer/OSD glass backplates have clear fills so an opaque foreground shape cannot hide the glass. No Expo/React Native runtime or npm dependencies were introduced.

## Validation

- Standalone offscreen corner rendering: 10 checks, including all four nested corners, standalone fallback rounding, and border thickness.
- Native notch input regression: 71 checks.
- Liquid Glass accessibility surfaces: 8 offscreen checks, including opaque dark/light fallbacks, circular/concentric shape preservation, retained foreground content, and Increased Contrast outlines. These exercise the shared fallback drawing primitives; ImageRenderer does not validate the system's GPU-backed glass compositor.
- Isolated live native window: visually checked Clear/Regular glass and concentric nested cards. Corrected the initially tested background-only glass placement because it blurred foreground text inside GlassEffectContainer; the final implementation attaches glass to the content as Apple prescribes.
- Separately verified the existing backplate/overlaid-content pattern without a global glass container: foreground labels and text fields remain sharp. Reintroduced global grouping in the isolated preview to reproduce the blur, then removed that grouping from the production roots.
- Live focus check in that window: typed `focus before`, switched to the opaque accessibility preview using a keyboard shortcut, typed ` and after`, restored native glass, then typed ` glass again`. Accessibility confirmed the same text field remained focused and contained `focus before and after glass again` across both transitions. System accessibility preferences were not modified.
- Optimized Release builds passed for the corner migration, native glass migration, and preview teardown follow-up. Deep/strict code-signature verification passed for the built and installed app.
- Installed `/Applications/Anchor.app` matches the final build executable SHA-256: `ab06efb7123928294b84e4f2f18c0b0196c7813bd852c4eb32dbc5ef5233bf32`.
- Live installed UI checks passed before the teardown-only follow-up: native General settings, feature cards, imported tool settings, settings search typing, Dashboard draft typing, and the Custom Liquid lock-screen mock preview. Preview foreground labels and media controls were sharp. The test task draft was cleared without adding a task; the existing task count remained unchanged.
- Restored the original lock-screen preferences after the preview check: Frosted Glass material and Standard mode. Saved preset IDs were not changed. Closed all review windows and stopped the isolated review application.

## Resource check and preview follow-up

Short 30-second observations before UI review showed mean CPU 1.26% and RSS 27.0 MB. After exercising and closing the preview and settings, mean CPU was 12.73% and RSS 62.5 MB; a later quiet repeat was 13.25% and 105.3 MB. These are diagnostic observations under different loaded-view conditions, not a controlled performance comparison of corner or glass APIs.

Inspection found that `closePreviewWindow` only ordered out its window while retaining the full hosting view and the music panel's progress TimelineView. Closing now detaches the hosted content and releases the preview window, host, and delegate. Reopening creates a fresh disposable preview, avoiding an intentionally retained hidden rendering graph.

The follow-up was built, signed, installed, and its binary hash verified. After manual unlock, the installed preview opened, closed using its window close button, reopened with its artwork, title, and playback controls rendered correctly, and closed again. The settings and preview windows were then confirmed absent from the app's accessibility tree. Frosted Glass remained selected throughout this follow-up; no playback controls or preferences were changed. The displayed media state was paused.

The first 30-second observation after closing averaged 8.20% CPU (median 2.40%, p90 17.77%, maximum 39.96%) and RSS 235.9 MB (maximum 359.4 MB). A quiet 30-second repeat averaged 1.79% CPU (median 1.92%, p90 2.40%, maximum 2.42%) and RSS 66.0 MB (maximum 95.3 MB), with the same installed process throughout. A three-second process sample between those observations showed the main thread predominantly waiting for events, with no sampled preview/TimelineView rendering activity. This supports the lifecycle correction under the observed conditions, but does not prove the origin of every transient spike or constitute a controlled before/after benchmark: media and loaded-view state differed from the earlier observations. Active-playback teardown was not separately exercised in this follow-up.

Actual locked-screen rendering was not exercised; the live material check used Anchor's mock preview.
