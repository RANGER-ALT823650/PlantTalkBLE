# iMessage-Style Message Flight Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** Use one iMessage-style overlay flight for both the home composer launch and messages sent from the conversation composer.

**Architecture:** `ContentView` owns a shared coordinate space and a single transient flight overlay. Composer views submit immutable flight requests, destination bubbles participate in layout while hidden, and the parent atomically swaps the overlay for the real bubble when the animation completes. Persistence updates message data without replacing the rendered row identity.

**Tech Stack:** Swift 5, SwiftUI, iOS 17+, iOS 26 Liquid Glass compatibility

---

### Task 1: Add the shared flight coordinator

**Files:**
- Modify: `ios/PlantTalkBLE/ContentView.swift`

1. Add shared flight request, state, coordinate-space, and destination preference types.
2. Render one top-level overlay from the captured source frame.
3. Animate it to the measured destination frame with a short smooth curve.
4. Reveal the real destination and remove the overlay in one non-animated transaction.

### Task 2: Convert the home launch

**Files:**
- Modify: `ios/PlantTalkBLE/ContentView.swift`
- Modify: `ios/PlantTalkBLE/TextConversationView.swift`

1. Measure the home input surface before send.
2. Remove the cross-screen matched-geometry namespace and temporary transition surfaces.
3. Insert the conversation screen immediately with its first bubble hidden but laid out.
4. Start the initial network request only after the overlay reaches the first bubble.

### Task 3: Convert conversation composer sends

**Files:**
- Modify: `ios/PlantTalkBLE/TextConversationView.swift`

1. Measure the conversation input surface.
2. Insert a provisional user message immediately and hide its bubble while reporting its destination frame.
3. Submit a flight request to `ContentView` and clear the live composer.
4. Replace provisional data after persistence without changing the message id or UI row.
5. Restore the composer and cancel the overlay if preparation or persistence fails.

### Task 4: Verify both paths

**Files:**
- Test: `ios/PlantTalkBLE.xcodeproj`

1. Build the Debug simulator target with code signing disabled.
2. Run the existing unit-test target on an available simulator.
3. Confirm no matched-geometry path remains for either send flow and no duplicate first message is rendered.
