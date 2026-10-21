# Design QA — 2026-10-21

final result: passed

## Comparison target and evidence

- Source visual truth: `../docs/design/control-room-revised.jpg`, 1440×1024.
- Implementation: local director `/`, recording example at 00:12:36; `qa/director.png`, 1440×1024, CSS viewport 1440×1024, device scale factor 1.
- Full-view paired evidence: `qa/comparison.jpg` (source left, implementation right).
- Focused paired evidence: `qa/controls-comparison.jpg` (status, time, stop and end-task actions). This was inspected separately because control legibility matters.
- Guest surface: `qa/guest.png` / `qa/guest.jpg`. Its source is the mini-window specification in `../docs/design/README.md`, not a separate approved high-fidelity image.
- Responsive evidence: `qa/mobile.png` at CSS 390×844 (375px content width after scrollbar), `qa/tablet.png` at CSS 1024×900 (full page). No horizontal content overflow; controls remain reachable by scrolling on small screens.
- Initial screenshot `qa/director-before.png` retained for the layout issue below. Early screenshot width was reduced by the scrollbar; final comparison uses equal 1440×1024 images, no stretching of app content.

## Findings and correction history

1. **P2, fixed: bottom recording actions below desktop viewport.** Initial large media region plus status row pushed the primary controls off-screen. Limited preview height based on viewport and reduced header/status/footer spacing. Rechecked the corrected DOM: action area bottom 978.5px in 1024px viewport; page height 1024px. Final screenshot and paired comparison show all actions.
2. **P2, fixed: trial recording and normal start could overlap.** Moved trial status into the shared model, disabled start on every connected mock view during the ten-second trial, and added a regression test. Trial completes into ready; browser verification confirmed disabled start during trial and return to ready.
3. **P2, fixed: ready-state preview implied automatic refresh.** Ready/saved views now use on-demand inspection text, explicit stale-frame text after ten seconds, and inspection resets the shared timestamp. Recording simulates timestamp refresh every five seconds. No real frames are acquired.
4. No remaining actionable P0/P1/P2 findings within the mock prototype scope.

## Required fidelity surfaces

- **Fonts/typography:** system sans-serif with PingFang/Microsoft YaHei fallbacks, clear source/recording labels, tabular timer. Standard content 14–16px; simulation toolbar and small metadata intentionally smaller. Does not reproduce generated-image glyph imperfections.
- **Spacing/layout:** preserved dark two-column 1.9:1 desktop/camera workspace, source meters, four health sections, bottom action bar and separated end-task control. A narrow simulation toolbar and guest-preview entry are intentional additions. Desktop primary controls fit in viewport; mobile stacks panels.
- **Colors/tokens:** charcoal surfaces, subtle gray borders, warm white text, green health, red stop, red outline end-task. Meaning is conveyed by text as well as color.
- **Image quality/assets:** generated matching portrait and slide-editor raster assets; no CSS/SVG substitutes for imagery. Native meter elements replace segmented cosmetic bars to retain useful meter semantics. Image content is simulated and not an exact identity match to the concept image.
- **Copy/content:** distinct stop vs end task, persistent simulation notice, local-material retention statement, stale/unknown connection messaging, explicit failed-save and recovery state. Materials control is disabled until a Take exists, intentionally unlike a permanently enabled mock button.
- **Icons/accessibility:** Phosphor icon library, native buttons/labels/selects/checkboxes, named icon controls, native modal dialogs with Escape handling and focus restoration intent. No custom-drawn pictorial SVG assets.

## Browser interactions verified

- Director and guest views opened with shared mock state; a second director browser tab sees the same state and its stop action is reflected in the first tab.
- Start, three-second countdown, recording, stop, saving and saved.
- Guest settings expand, output-directory edit, ten-second trial locks and completion; settings collapse back to mini-window.
- Materials page, 20-frame pagination into page two and frame enlargement/close.
- Network loss disables director control; guest local stop still works.
- Injected save failure preserves recovery action; retry completes.
- End-task confirmation, simulated cleanup, guest widget disappears, director controls disabled.
- Browser console error/warning check: none captured on director page during final verification.

## Follow-up polish and limits

- P3: refine exact preview crop, meter appearance and small metadata sizing after product review. Native guest window is currently about260×100 logical pixels for legibility, versus the initial240×88 estimate.
- Full screen-reader audit, 200% zoom and native macOS/Windows positioning/capture exclusion are not verified. This browser prototype cannot establish native behavior.
- Cross-device synchronization, actual media recording, secure remote authorization and uninstall are absent by design. Local storage + Web Locks only emulate same-browser tabs.
- Complete build and eight model tests pass; these are not hardware or production acceptance.

## Implementation checklist

- [x] Correct desktop action visibility and recompare.
- [x] Verify both surfaces and critical mock transitions.
- [x] Inspect full-view and focused visual comparison.
- [x] Verify390px and1024px layouts, capture console status.
- [x] Preserve local preview for user review; no deployment or Git commit.
