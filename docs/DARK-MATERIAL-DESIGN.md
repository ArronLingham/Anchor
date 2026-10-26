# Anchor dark material design

The app uses a permanent dark appearance, neutral charcoal surfaces, white accents,
and warm-white content. Soft raised controls sit above recessed fields and dark glass
cards. Layout and spacing identify hierarchy before effects do.

- `AnchorDesign.swift` owns palette, surfaces, controls, forms, and headers.
- Glass cards use system material plus a dark scrim and an illuminated upper edge.
- Buttons use paired light/dark shadows; a pressed button becomes recessed.
- Settings use a dedicated sidebar, page header, and section cards. The same native
  controls, identifiers, search navigation, and stored preferences remain in use.
- The dashboard, launcher, clipboard, notch, independent player panels, HUDs,
  onboarding, and sheets share the same dark control styles.
- Reduce Transparency replaces material with an opaque fill; Increase Contrast
  strengthens edges; Reduce Motion removes custom control motion.
- Shadows and gradients are static. There are no animation timers for decoration.
- OS-owned permissions, authentication websites, artwork, and other apps retain
  their own appearance. Anchor's chrome is always dark.

Research consulted 2026-10-15:

- NN/g, [Glassmorphism: Definition and Best Practices](https://www.nngroup.com/articles/glassmorphism/):
  blur and translucency establish depth; protect readability and support reduced transparency.
- NN/g, [Skeuomorphism](https://www.nngroup.com/articles/skeuomorphism/):
  neumorphic shadows need clear clickability and sufficient contrast.
- Apple, [Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
  [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode):
  use material and semantic hierarchy consistently.

Validation uses Debug-only offscreen renders of every settings pane and key surfaces,
plus the signed installed Release and live navigation. Physical lock/unlock and all
external integrations still require their own behavioral testing when changed.
