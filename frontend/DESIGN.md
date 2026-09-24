---
name: BarkVisor Frontend
description: "The Instrument Panel: compact, calm, and practical."
colors:
  accent: "#0090f8"
  accent-light: "#0078d4"
  accent-hover: "#2ea8ff"
  accent-hover-light: "#006abc"
  accent-muted: rgba(0,144,248,0.12)
  accent-muted-light: rgba(0,144,248,0.10)
  accent-text: "#fff"
  bg: "#0a0e14"
  bg-light: "#f6f6f5"
  panel: rgba(255,255,255,0.03)
  panel-light: rgba(0,0,0,0.02)
  bg-card: rgba(0,144,248,0.05)
  bg-card-light: rgba(255,255,255,0.8)
  bg-hover: rgba(0,144,248,0.08)
  bg-hover-light: rgba(0,144,248,0.06)
  bg-input: rgba(0,0,0,0.35)
  bg-input-light: rgba(255,255,255,0.9)
  sidebar-bg: rgba(8,12,18,0.92)
  sidebar-bg-light: rgba(255,255,255,0.92)
  text: "#e4e4e2"
  text-light: "#141618"
  text-secondary: "#b8b8b4"
  text-secondary-light: "#4a4a48"
  text-dim: "#6e6e6c"
  text-dim-light: "#8a8a88"
  line: rgba(255,255,255,0.07)
  line-light: rgba(0,0,0,0.08)
  border-glass: rgba(184,184,180,0.12)
  border-glass-light: rgba(0,0,0,0.10)
  modal-surface: "#0c1118"
  modal-surface-light: "#ffffff"
  green: "#34d399"
  green-light: "#059669"
  green-muted: rgba(52,211,153,0.10)
  green-muted-light: rgba(5,150,105,0.10)
  red: "#f87171"
  red-light: "#dc2626"
  red-muted: rgba(248,113,113,0.10)
  red-muted-light: rgba(220,38,38,0.08)
  amber: "#fbbf24"
  amber-light: "#d97706"
  amber-muted: rgba(251,191,36,0.10)
  amber-muted-light: rgba(217,119,6,0.10)
  gray: "#6b7280"
  gray-muted: rgba(107,114,128,0.10)
  gray-muted-light: rgba(107,114,128,0.08)
typography:
  headline:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 16px
    fontWeight: 700
    lineHeight: 1.5
    letterSpacing: -0.01em
  dialog-title:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 17px
    fontWeight: 700
    lineHeight: 1.5
  body:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
  field:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 13px
    fontWeight: 400
  control:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 12.5px
    fontWeight: 600
  label:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 11px
    fontWeight: 600
    lineHeight: 1.5
    letterSpacing: 0.06em
  badge:
    fontFamily: Inter, -apple-system, BlinkMacSystemFont, sans-serif
    fontSize: 9.5px
    fontWeight: 700
    lineHeight: 1.5
    letterSpacing: 0.05em
  mono:
    fontFamily: "'SF Mono', 'Fira Code', 'Cascadia Code', monospace"
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  base: 2px
  icon-tile: 8px
spacing:
  "6": 6px
  "8": 8px
  "10": 10px
  "12": 12px
  "14": 14px
  "16": 16px
  "18": 18px
  "22": 22px
  "24": 24px
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.accent-text}"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: 0px 14px
    height: 32px
  button-ghost:
    backgroundColor: transparent
    textColor: "{colors.text-dim}"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: 0px 14px
    height: 32px
  button-danger:
    backgroundColor: transparent
    textColor: "{colors.red}"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: 0px 14px
    height: 32px
  button-warning:
    backgroundColor: rgba(251, 191, 36, 0.15)
    textColor: "{colors.amber}"
    typography: "{typography.control}"
    rounded: "{rounded.base}"
    padding: 0px 14px
    height: 32px
  text-field:
    backgroundColor: "{colors.bg-input}"
    textColor: "{colors.text}"
    typography: "{typography.field}"
    rounded: "{rounded.base}"
    padding: 10px 14px
  navigation-item:
    backgroundColor: transparent
    textColor: "{colors.text-dim}"
    rounded: "{rounded.base}"
    padding: 6px 8px
  status-running:
    backgroundColor: transparent
    textColor: "{colors.green}"
    padding: 0px
  device-card:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.base}"
    padding: 11px 12px
  gallery-card:
    backgroundColor: "{colors.panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.base}"
    padding: 16px 14px
  modal-frame:
    backgroundColor: "{colors.modal-surface}"
    textColor: "{colors.text}"
    rounded: "{rounded.base}"
    width: 640px
---

# Design System: BarkVisor Frontend

## Overview

**Creative North Star: "The Instrument Panel"**.

The Instrument Panel is compact, calm, and practical. Small, precise controls
sit within a stable navigation frame. Fine borders and quiet surfaces organize
dense information; blue identifies actions and selection, while labeled status
colors make running state legible.

Buttons, fields, and cards are compact, precise, and restrained. Panels sit
mostly flat against the canvas. Overlays gain structural depth through a
backdrop and shadow. Light and dark appearances preserve the same hierarchy,
dimensions, and interaction vocabulary.

**Key Characteristics:**

- Compact controls and closely grouped actions.
- Signal Blue over Night Slate or Soft Chalk.
- Nearly square containers with fine boundaries.
- Inter for interface text and explicit monospace treatments for technical
  content.
- Flat working panels with lifted overlays.

The implementation anchors are [global styles](src/style.css),
[shared controls](src/components/ui/), [theme handling](src/stores/theme.ts),
and the [creation gallery](src/components/create-vm/CreateVMGalleryStep.vue).

## Colors

The palette pairs a clear blue action color with quiet neutral canvases.
Unsuffixed color tokens mirror the base dark theme; their `-light` partners
record the light-theme overrides. Component previews inherit the live CSS
variables. Tonal ramps in the sidecar are generated swatch previews.

### Primary

**Signal Blue** marks primary actions, selected navigation, links, and resource
meters. Its muted wash supports selected and hovered surfaces.

### Neutral

**Night Slate** is the dark canvas; **Soft Chalk** is the light canvas. Primary,
secondary, and quiet text establish hierarchy. Thin hairlines and translucent
panel layers separate regions. Inputs and overlays have dedicated surfaces.

### Status

**Ready Green** identifies running and healthy states. **Failure Red**
identifies failures and destructive actions. **Attention Amber** identifies
transitional states and warnings. **Stopped Gray** identifies stopped states.
Keep the accompanying labels and dots.

**The Theme Pair Rule.** Resolve shared colors through the active theme
variables so light and dark appearances preserve their intended roles.

## Typography

Inter is the interface face, with the platform sans-serif fallbacks recorded in
the tokens. Technical text has an explicit monospace utility; log streams use
`ui-monospace, 'SF Mono', Menlo, monospace` at 11.5 px with a 1.75 line height.

The hierarchy is closely spaced: compact bold page headings, slightly larger
dialog headings, regular body text, semibold controls, and tracked uppercase
labels and badges. Numeric counters use tabular figures where implemented. Page
headings reduce to 15 px on mobile. Gallery and Device names use 13.5 px
semibold text. The frontmatter records the reusable roles.

## Layout

The viewport-height desktop shell has a 200 px sidebar, a 30 px status strip,
and a 58 px page toolbar. The main working region scrolls independently, with 14
px vertical and 16 px horizontal padding. Related toolbar actions use an 8 px
gap. The spacing tokens record recurring measurements from the source.

Device grids fill available width with columns of at least 280 px. The dashboard
uses a flexible feed beside a 320 px supporting column, with a 24 px gutter. Its
columns and other split detail views stack at 900 px.

At 768 px, the sidebar becomes a header with a menu that opens across the
viewport. Toolbars wrap, page padding becomes 12 px with safe-area insets, and
tables retain contained horizontal scrolling with a 560 px minimum width.
Generic form fields increase to 16 px; compact selects and searches retain their
component sizing. The 1024 px rules adjust page headings, grids, and modal
widths.

**The Aligned Controls Rule.** Use the shared control height for toolbar
buttons, searches, and selects; the small button variant changes horizontal
padding.

## Elevation & Depth

Depth is structural. Dashboard panels, Device cards, and data tables use fine
borders and tonal separation. The sidebar uses a 40 px backdrop blur; generic
fields and glass surfaces use 24 px blur and a faint inset highlight.

The sidecar records the exact shadow vocabulary: the inset glass highlight,
theme-specific large overlay shadows, the stronger shared modal shadow, and the
generic field focus halo. Creation galleries and repository menus use the large
theme-aware shadow; shared modal frames use the stronger fixed shadow.

**The Structural Depth Rule.** Use boundaries and surface tones for working
panels, and reserve substantial lift for overlays.

## Shapes

The common corner is nearly square, using the base radius throughout controls,
panels, badges, and dialog frames. Gallery icon tiles use the larger icon
radius. Status dots and numbered wizard markers are circular. Borders are
generally one pixel; selected navigation uses a two-pixel edge marker.

## Components

### Buttons

Shared buttons have matching heights, semibold text, and compact horizontal
padding. The small variant uses 12 px horizontal padding. Primary buttons are
filled blue; ghost buttons are outlined and quiet; danger buttons combine red
text with a red outline. Warning buttons retain their fixed gold text, wash, and
outline in both themes. Hover changes color or boundary, and disabled shared
buttons use 0.4 opacity. Their state transitions last 120 ms. Shared buttons
retain the browser's keyboard focus outline.

### Fields and selects

Generic fields use inset surfaces, a fine border, and an inset highlight. Their
focus treatment is a lavender border with a faint three-pixel halo. Compact
selects use the action blue border and a two-pixel accent halo. Labels are
small, uppercase, and tracked. Field transitions use the shared 200 ms easing.

### Navigation and tabs

Sidebar links pair small line icons with labels. Selection adds a blue wash and
a left edge marker. Page tabs use a blue underline; the compact tab-group
component uses an outlined selection. Navigation follows the shared 200 ms
transition, while compact tab groups use 150 ms transitions.

### Status and badges

Global status labels pair uppercase text with a small colored dot on a
transparent surface. Transitional dots pulse over 1.4 seconds; the live status
indicator pulses over 1.5 seconds. Badges use small tracked text and muted
semantic fills. Dashboard status chips use a roomier text-and-dot treatment.

### Cards and tables

Device cards are flat, outlined, and compact, with name, metadata, and resource
meters. Selection adds a blue wash and inset edge marker. Dashboard panels have
16 px padding. Tables have sticky uppercase column headings, subtle row hover,
fine row separators, and a flat scrollable container.

### Dialogs and creation galleries

Shared modal frames separate title, body, and actions with rules. Standard
frames are 640 px wide; split frames are 820 by 560 px with a 220 px rail;
narrow split frames are 480 px wide. They are bounded by the viewport. On
mobile, shared frames become full-width; narrow split frames sit against the
bottom.

The VM creation gallery uses an 820 by 560 px frame; the App gallery uses a 720
px frame. Both keep a 24 px outer inset and a 90 vh height bound. Their
three-column shelves use small icon tiles, names, descriptions, and a dashed
custom-entry row. The VM gallery marks selection with a blue boundary and wash.

## Do's and Don'ts

### Do

- Do reuse the shared controls and the active theme variables.
- Do keep status words beside their colored indicators.
- Do preserve the compact toolbar rhythm and clear page headings.
- Do use the established mobile menu, wrapping toolbars, and contained
  scrolling.
- Do retain the focus behavior of the component being reused.

### Don't

- Don't replace status colors with decorative accent colors.
- Don't apply overlay shadows to ordinary table and Device panels.
- Don't turn the common square-cornered controls into pills.
- Don't force the desktop sidebar width onto the mobile layout.
