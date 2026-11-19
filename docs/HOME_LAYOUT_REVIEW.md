# Home layout review

Sources read: Apple Human Interface Guidelines, current official Markdown editions.

- Layout: https://developer.apple.com/design/human-interface-guidelines/layout — respect safe areas, group related content, maintain hierarchy, and adapt to available space.
- Tab bars: https://developer.apple.com/design/human-interface-guidelines/tab-bars — the tab bar is a navigation layer floating above content on iPhone.
- Buttons: https://developer.apple.com/design/human-interface-guidelines/buttons — distinguish actions clearly, leave space around them, and provide press feedback; generally use 44×44pt hit regions.
- Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility — control spacing matters alongside control size.

## Applied choices

The former layout expanded to within about 4pt of the content boundary. The home now reserves a 24px visual gutter beyond the already-owned safe area or reported native overlay inset. This is an app-specific spacing choice, not an Apple requirement. Maximum adaptive spacing is capped at 4px so extra screen height remains below the content instead of stretching every section to the bottom.

Daily feelings and posture actions remain grouped, each with a 44px target and its own quiet button surface. Posture gets a soft accent and a completed state; custom actions provide press feedback. Metric and summary text sizes remain unchanged. Full observations remain available through their detail sheet.

## Validation

Dashboard interaction test and production build. Browser checks with representative fixtures: native available heights 650/680px, 90px overlay, long summaries, dark mode, web viewports 402×874 and 390×780, desktop and resize. Check both zero vertical overflow and at least 24px clearance above the navigation exclusion zone. These checks simulate layout space; they are not a physical iPhone test.
