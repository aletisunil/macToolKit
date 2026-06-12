# Design — macToolKit

Locked design system for this native macOS menu-bar app. Every UI surface
(menu panel, settings, onboarding, HUD) reads this file before changing.
Amend this file when the system needs to grow; do not override per-surface.

## Genre
Modern-minimal, native macOS dialect. System materials, SF Pro, AppKit
vibrancy. No imported web fonts — native craft over web styling.

## Identity spine
One tint per feature, used identically on every surface:

- Finder Tools — blue
- Color Temperature — orange
- Rewritely — purple
- Scroll Reverser — teal
- General / About — gray

Tints render as System-Settings-style gradient icon tiles (`IconTile` in
`macToolKit/Support/Theme.swift`): continuous-corner rounded square,
top-lightened linear gradient (`tint.mix(white, 0.22) → tint`), white SF
symbol at 0.48 × side, soft tint shadow.

## Surfaces
- **Menu bar** — standard `.menu`-style NSMenu: plain feature toggles,
  Show in Dock, Settings…, Quit. Deliberately native-plain; the visual
  identity lives in the windows, not the menu.
- **Settings** — 840 × 560, slim sidebar (tiles + hover + accent selection),
  detail pane of rounded cards. Hero card per pane: 38 pt tile + title +
  subtitle + status chip.
- **Onboarding** — 460 × 560, six pages, tiles replace bare symbols.

## Color
- Paper: cream #F6F1E7 light / system window background dark
  (`NSColor.appWindowBackground`).
- Cards: cream-white #FDFBF5 light / 5.5 % white dark. Sidebar one step
  darker than paper (#EDE7D9 light).
- Status: green dot = on, orange = waiting on permission. No other
  semantic colors.

## Typography
SF Pro only. Headline for titles, callout/medium for row titles, caption
secondary for status lines, caption2 semibold +1.1 kerning uppercase for
sidebar section labels. Monospaced only for values (kelvin badge, triggers).

## Motion
- Hover states on every clickable row (quaternary fill, 9 pt radius).
- Settings pane switch: 180 ms ease-out opacity crossfade. Nothing else
  animates on navigation.
- System defaults handle reduced motion.

## Voice
- Status lines state facts ("3400 K", "Trackpad reversed", "2 triggers"),
  never marketing.
- Permission waits are calm orange sentences, not alerts.
- Silent success everywhere; no toasts, no celebration.
