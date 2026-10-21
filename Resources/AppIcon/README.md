# Checklist application icon

`source.png` is the retained square, transparent artwork generated with the built-in imagegen tool on 16 October 2026. Its native dimensions are 1254 × 1254. `../AppIcon.icns` contains the standard 16–1024 pixel macOS representations, downsampled with `sips` and packaged with `iconutil`; no size was upscaled or redrawn.

Regenerate with `./scripts/make-app-icon.sh`. The build captures the `.icns`, declares it in `CFBundleIconFile` and verifies its bytes before installation.

## Generation prompt

Use case: logo-brand
Asset type: production macOS application icon for Checklist, a native checklist app for independent game and app production.
Primary request: Create one beautifully resolved, instantly readable macOS Dock icon. A softly rounded square tile in deep teal with a restrained turquoise upper glow. Center a bold, warm-white checklist mark: three generous horizontal rows, with a large confident check on the first row and small rounded empty checks below. The mark should feel like one carefully designed emblem rather than a detailed screenshot.
Style: refined native macOS icon, restrained dimensional ceramic or satin enamel surface, very subtle inset relief and soft edge lighting; clean, approachable, professional.
Composition: a single front-facing square icon, centered, symmetrical optical balance, roomy padding, crisp simple shapes readable at 16 and 32 pixels. The rounded-square body occupies roughly 82 percent of the square canvas, with transparent area outside its rounded corners and a subtle contained shadow.
Constraints: true transparent background outside the icon body, no surrounding scene, no device mockup, no words, no letters, no numbers, no tiny badges, no robots, no gears, no decorative confetti. Deliver just one square app icon.
