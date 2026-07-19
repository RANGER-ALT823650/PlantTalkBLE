# Telegram iOS Reference Audit Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Compare Plant Talk's SwiftUI chat and home-screen implementation with the official Telegram iOS source, then apply only demonstrably safer or more efficient patterns that preserve the project's documented product preferences.

**Architecture:** Clone Telegram iOS into a temporary read-only reference checkout and map each relevant item in `Software build preference.md` to concrete Telegram source locations. Treat Telegram's UIKit/Texture implementation as behavioral and architectural evidence rather than a drop-in dependency; reimplement applicable ideas in small SwiftUI components, preserving stable message identity, local state ownership, Liquid Glass availability gates, accessibility fallbacks, and the existing GRDB/network flow. Do not copy license-covered source verbatim without explicitly documenting the licensing consequence.

**Tech Stack:** SwiftUI, Swift concurrency, GRDB, Xcode 26, iOS 17+, iOS 26 Liquid Glass, Git/GitHub, Telegram iOS UIKit/Texture reference source.

---

### Task 1: Resolve and acquire the official reference repository

**Files:**
- Read: `Software build preference.md`
- Temporary clone: `/tmp/telegram-ios-reference`
- Create: `docs/plans/2026-07-10-telegram-ios-reference-audit.md`

**Step 1:** Verify the official Telegram iOS repository URL, default branch, current license, and repository size from GitHub.

**Step 2:** Clone the repository into `/tmp/telegram-ios-reference` using a shallow, blob-filtered checkout when supported.

**Step 3:** Record the inspected commit hash so every comparison is reproducible.

### Task 2: Locate Telegram implementations corresponding to the preferences

**Files:**
- Read: `/tmp/telegram-ios-reference/submodules/TelegramUI/**`
- Read: `/tmp/telegram-ios-reference/submodules/Display/**`
- Read: `/tmp/telegram-ios-reference/submodules/AsyncDisplayKit/**`
- Read: `ios/PlantTalkBLE/ContentView.swift`
- Read: `ios/PlantTalkBLE/TextConversationView.swift`

**Step 1:** Search Telegram for chat input panels, send actions, message insertion animations, bubble layout, typing/activity indicators, theme propagation, keyboard handling, and stable list identity.

**Step 2:** Map each relevant preference to exact Telegram files and symbols.

**Step 3:** Classify each pattern as `adopt`, `adapt`, or `reject`, with a short reason based on SwiftUI fit, complexity, performance, and licensing.

### Task 3: Audit Plant Talk against the reference

**Files:**
- Read: `ios/PlantTalkBLE/ContentView.swift`
- Read: `ios/PlantTalkBLE/TextConversationView.swift`
- Read: `ios/PlantTalkBLE/ChatModels.swift`
- Read: `ios/PlantTalkBLE/ConversationListView.swift`

**Step 1:** Check state ownership and invalidation scope, especially the streaming `messages` array and per-token updates.

**Step 2:** Check stable identity and transition identity for initial and subsequent outgoing messages.

**Step 3:** Check layout work, formatter work, filtering, scrolling, and animation scope performed during body recomputation.

**Step 4:** Identify only changes with concrete evidence of lower invalidation, less layout work, or more reliable visual continuity.

### Task 4: Implement targeted improvements

**Files:**
- Modify: `ios/PlantTalkBLE/TextConversationView.swift`
- Modify only if required: `ios/PlantTalkBLE/ContentView.swift`
- Modify only if required: `ios/PlantTalkBLE/ChatModels.swift`

**Step 1:** Extract a reusable send-transition component/state if Telegram's separation of input, transition snapshot, and message list is materially clearer.

**Step 2:** Narrow per-token view invalidation and avoid filtering or formatting work that repeats unnecessarily during streaming.

**Step 3:** Preserve content-sized bubbles, keyboard focus, top thinking indicator, Liquid Glass/fallback surfaces, and Reduce Motion behavior.

**Step 4:** Keep the existing network and database semantics unchanged unless the comparison exposes a correctness issue.

### Task 5: Verify behavior and document the audit

**Files:**
- Modify: `Software build preference.md`
- Modify: `项目进度.md`
- Create: `docs/telegram-ios-reference-audit.md`

**Step 1:** Build the iPhone 17 / iOS 26.5 simulator target.

Run:

```bash
xcodebuild -project ios/PlantTalkBLE.xcodeproj -scheme PlantTalkBLE -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: `BUILD SUCCEEDED`.

**Step 2:** Run the existing unit tests.

Run:

```bash
xcodebuild -project ios/PlantTalkBLE.xcodeproj -scheme PlantTalkBLE -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

Expected: all existing tests pass.

**Step 3:** Write `docs/telegram-ios-reference-audit.md` with the Telegram commit, exact source references, preference mapping, adopted/rejected patterns, licensing boundary, and validation results.

**Step 4:** Update the implementation section of `Software build preference.md` and the software milestone section of `项目进度.md` only where the actual implementation changed.

**Step 5:** Since this workspace is not a Git repository, do not create commits; report the exact changed files for manual version control.
