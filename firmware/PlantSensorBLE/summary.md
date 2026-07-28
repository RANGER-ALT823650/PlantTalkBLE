2026-07-28 19:35:24 CST

# What changed

- Restored the GPIO 2 blue status LED as a Wi-Fi indicator.
- The LED toggles every 500 ms while Wi-Fi is disconnected or retrying.
- The LED stays on while the ESP32 station is associated with Wi-Fi.
- BLE-only builds keep the LED off.
- NTP synchronization now runs in the background and no longer blocks cloud
  command polling when UDP time servers are unavailable.
- HTTPS requests temporarily disable modem sleep, allow a 20-second TLS
  handshake, and log the underlying transport/TLS error when connection fails.
- The cloud task stack is 12 KiB so TLS and JSON work have explicit headroom.
- Replaced the Bluedroid BLE implementation with NimBLE-Arduino 2.5.0 while
  preserving the service UUIDs, characteristic UUIDs, properties, and binary
  protocol.
- Future-timestamp repair now walks the logical history sequence range rather
  than every empty physical slot in a sparse ring file.
- Every reading committed to LittleFS, including the normal five-minute sample,
  is now queued for `/sync/push`; Wi-Fi no longer uploads only readings created
  by an immediate cloud command.
- The upload task peeks the oldest queued reading and removes it only after a
  successful cloud response. The 64-entry queue buffers about 5 hours 20 minutes
  at the current cadence.
- Queue insertion is independent of the immediate-command result mutex, so a
  scheduled reading cannot miss Wi-Fi delivery merely because command polling
  is reading its mailbox at the same instant.
- HTTPS command polling now consumes the cloud `serverTime` field, so networks
  that block NTP/UDP 123 can still establish an exact clock before sampling.

# Why

The previous LED task was removed from the current firmware and drove several unrelated GPIO pins. The replacement is a non-blocking main-loop state machine that only uses the declared `STATUS_LED_PIN`.

NTP is treated as a time-quality enhancement rather than a cloud-connectivity
requirement. Readings remain explicitly marked with estimated timestamps until
either the HTTPS response clock or SNTP succeeds.

The ESP32 remained associated with Wi-Fi but repeatedly returned HTTP error
`-1` while the same access point could reach the FC endpoint. Keeping the radio
awake only during HTTPS avoids extending high-power Wi-Fi behavior into idle
time or BLE maintenance sessions.

The added transport diagnostic identified the actual TLS failure as memory
allocation at roughly 19 KiB free heap. NimBLE uses less runtime memory than
Bluedroid, leaving enough contiguous heap for HTTPS without removing BLE support
or sending the authentication token over plaintext HTTP.

Epoch-sized sequence IDs can make a small ring history file physically sparse.
Scanning the file extent twice during startup delayed BLE and Wi-Fi
initialization for an unbounded time; logical sequence traversal keeps boot work
proportional to the actual retained record count.

Previously, the scheduler stored five-minute readings only in LittleFS.
`/sync/push` was reached only by the immediate-command response path, so Web and
iOS could not discover ordinary samples without a BLE history transfer. The
new queue attaches cloud delivery to the successful LittleFS commit and keeps
the same `(deviceId, sequence)` identity across Wi-Fi and BLE.

# Safe to modify

- `WIFI_SEARCH_LED_TOGGLE_MS` controls the blink rate.
- `STATUS_LED_ON_LEVEL` and `STATUS_LED_OFF_LEVEL` can be swapped for an active-low board.
- The NTP server list passed to `configTime` can be changed without affecting
  cloud polling.
- `CLOUD_HTTP_TIMEOUT_MS` and
  `CLOUD_TLS_HANDSHAKE_TIMEOUT_SECONDS` can be increased for unusually slow
  networks, at the cost of slower failure recovery.
- BLE display names and advertising intervals can be changed without altering
  the app protocol; keep the four UUID constants synchronized with iOS and Web.
- Timestamp-repair plausibility thresholds can be adjusted independently of the
  logical sequence traversal.
- `CLOUD_HISTORY_UPLOAD_QUEUE_DEPTH` can be increased if a longer connected
  cloud outage must be buffered, subject to ESP32 heap limits.

# Risky to modify

- Do not add other GPIO pins to the status indicator without checking boot straps, I2C wiring, and attached sensors.
- Do not replace the non-blocking timer with `delay`, because BLE history transfer and control commands depend on a responsive loop.
- Do not restore an NTP failure `continue` before `runCloudPollCycle`; doing so
  disables remote sampling on networks that block UDP/123.
- Keep `WiFi.setSleep(true)` on every return path after an HTTPS request. Leaving
  modem sleep disabled continuously increases power use and reduces BLE airtime.
- Reducing `CLOUD_TASK_STACK_BYTES` below the measured TLS workload can cause
  intermittent failures that resemble network faults.
- Do not restore explicit `0x2902` descriptor allocation when using NimBLE;
  notification characteristics manage their CCCD internally.
- Changing characteristic properties or callback parsing changes the on-wire
  BLE protocol and requires matching iOS/Web changes.
- Keep the logical-to-physical slot formula synchronized with
  `appendHistoryRecord` and `readHistoryRecord`.
- Do not dequeue a pending cloud reading before `/sync/push` returns success;
  doing so would silently lose scheduled samples during transient failures.
- Do not assign a new sequence on the Wi-Fi task. Cloud and BLE must converge on
  the sequence already committed to LittleFS.

# Assumptions and constraints

- The current board's blue LED is connected to GPIO 2 and is active high.
- “Connected” means `WiFi.status() == WL_CONNECTED`; it does not guarantee that the cloud endpoint is reachable.
- Cloud HTTPS requests are attempted only when no BLE client is connected.
- The build environment must have NimBLE-Arduino 2.5.0 or a compatible 2.x
  release installed.
- The cloud upload queue is RAM-only. A reboot can discard pending Wi-Fi
  deliveries, but the readings remain durable in LittleFS and recoverable by
  the BLE history protocol.
- Immediate-command readings may reach both `/command/respond` and
  `/sync/push`; Tablestore's `(device_id, sequence)` key makes this idempotent.

# Suggested next improvement

- Persist the pending Wi-Fi upload cursor in NVS/LittleFS if automatic recovery
  across a reboot is required without waiting for a later BLE sync.
