# HermesOBD (macOS)

HermesOBD is a live OBD-II dashboard for macOS, built for a 2005 Ford Mustang with a Bluetooth adapter sold for Innova's **RepairSolutions2** app. It shows live sensor data, reads trouble codes, logs to CSV, and has a clearly labeled simulator for testing without hardware.

The app only reads data, with one opt-in, guarded exception: [clearing trouble codes](#clearing-trouble-codes). It does not do tuning, actuator tests, or any other write.

> **Status:** Live data and trouble-code reading have been verified on a 2005 Mustang (CAN) with an **Innova 3210RS** adapter over Bluetooth LE (see [Tested adapter: Innova 3210RS](#tested-adapter-innova-3210rs)). Clearing codes and CSV logging on a real car haven't been tried yet. Other adapters and cars may behave differently.

---

## Contents

- [Quick start](#quick-start)
- [Adapter compatibility](#adapter-compatibility)
- [Connecting to the car](#connecting-to-the-car)
- [Permissions](#permissions)
- [What the app shows](#what-the-app-shows)
- [Safety and read-only design](#safety-and-read-only-design)
- [Clearing trouble codes](#clearing-trouble-codes)
- [CSV logging](#csv-logging)
- [Hermes Agent analysis](#hermes-agent-analysis)
- [Limitations](#limitations)
- [Once you know the adapter model](#once-you-know-the-adapter-model)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)

---

## Quick start

Requirements: macOS 14 or newer and Apple's Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

```bash
cd ~/Downloads/HermesOBD
./scripts/build-app.sh
open "dist/HermesOBD.app"
```

In the app, pick **Simulator** and click **Connect** to see the dashboard with fake data. Simulated data has an orange banner, orange labels, and `SIMULATED` in every CSV row.

Run the app as the `.app` bundle, not with `swift run`. macOS only grants Bluetooth access to a bundled app that declares why it needs it (`Resources/Info.plist`).

---

## Tested adapter: Innova 3210RS

What a live test with a 2005 Mustang showed:

| | |
|---|---|
| Bluetooth name | **`Dongle`** followed by a number. It doesn't say Innova or 3210RS. The app marks it **OBD?** and lists it first. |
| Link | Bluetooth LE, service `FFF0` (notify `FFF1`, write `FFF2`). No pairing in System Settings. |
| Adapter | Reports itself as `ELM327 v1.3a`, "OBDII to RS232 Interpreter" |
| Car protocol | Auto-detected: ISO 15765-4 CAN, 11-bit, 500 kbaud (`ATDPN` = `A6`) |
| Supported PIDs | The Mustang advertised 47. Every value on the dashboard read, including MAP and ambient temperature. |
| Trouble codes | Stored (03) and pending (07) work. Permanent codes (0A) aren't supported by the car (`7F 0A 11`). |

Adapter quirks the app now handles:
- **CAN headers on by default.** Replies come back like `7E8 06 41 00 …`. The app turns headers off, and its parser also accepts headered replies, including multi-frame ones.
- **`ATDP` acts like "restore defaults"** on this adapter, which turned headers back on mid-session. The app no longer sends `ATDP`. It gets the protocol from `ATDPN` and names it itself.

If the app can't find it:
- **Plug it into the car.** It only powers on from the OBD port. Turn the ignition ON.
- **Quit RepairSolutions2 on your phone,** or turn off the phone's Bluetooth. The adapter takes one connection at a time.
- **Look for `Dongle…`** in the Bluetooth LE list, not "Innova".

## Adapter compatibility

The app works with adapters that speak the standard **ELM327** command set over Bluetooth LE, Bluetooth Classic (serial), or Wi-Fi. Background on Innova's RepairSolutions2 adapters, from research in October 2026:

- **RepairSolutions2** is Innova's phone app. Several Innova dongles pair with it, including the **Innova 1000** and the **3210RS / 3215RS** sold at Canadian Tire.
- Innova's help center says the **Innova 1000** was designed to also accept the standard **ELM327** command set. It names third-party apps that worked: Car Scanner (in both Bluetooth Classic and BLE modes), OBD Auto Doctor (Classic), and EOBD-Facile (Classic). It also says some ELM327 commands may not work. ([Innova help article](https://rs2.helpscoutdocs.com/article/2319-will-the-innova-1000-work-with-general-obd2-elm327-compatible-apps). The link now redirects to a page that returned 404 at the time of writing; this summarizes what search results quoted from it.)
- A Canadian Tire listing describes the **3210RS** as containing ELM327 and Bluetooth, and says it pairs with most OBD2 apps. ([listing](https://www.canadiantire.ca/en/pdp/3210rs-bt-codereader-0251084p.0251084.html))
- Innova's iPhone setup guide says to pair **inside the app, not in phone Bluetooth settings**, and on Android it needs Location Services "for Bluetooth BLE". That suggests at least the 1000 uses BLE with the phone. ([iPhone troubleshooting](https://innova-electronics.helpscoutdocs.com/article/2736-innova-1000-iphone-or-ipad-troubleshooting), [Android troubleshooting](https://innova-electronics.helpscoutdocs.com/article/2737-innova-1000-android-troubleshooting))
- An Innova blog post says the RepairSolutions2 app is optional for most Innova scanners, but "dongle-based scanners are an exception". Some dongles may only work with Innova's app. ([Innova blog](https://www.innova.com/blogs/product-guides/is-the-repairsolutions2-app-required-to-use))
- Innova's FAQ says the 1000 and RS2 app only work in the US and Canada. ([1000 support](https://www.innova.com/pages/1000-qr-support))

There's **no Innova documentation about Mac use** and no published BLE service UUIDs, so the app doesn't assume a protocol: it speaks standard ELM327 and reports what happens. If an adapter only speaks a proprietary RepairSolutions2 protocol, this app won't work with it. That's expected, not a bug, and this project won't reverse-engineer it.

To check your Mac's Bluetooth support, run `system_profiler SPBluetoothDataType`. Most Macs support both BLE (GATT) and the Classic serial port profile.

---

## Connecting to the car

**Before any method:**

1. Plug the adapter into the OBD-II port, under the dashboard on the driver's side.
2. Turn the ignition to **ON**. Start the engine to see most live values.
3. **Quit RepairSolutions2 on your phone**, or turn the phone's Bluetooth off. Most adapters accept only one connection.

The app reports progress in stages. Only the last one means the car is actually talking:

| Status | Meaning |
|---|---|
| Opening link… | Connecting to the adapter over BLE / serial / TCP |
| Link open — waiting for the adapter to reply | Connected, but the adapter hasn't answered yet |
| Adapter replied — waiting for the vehicle | The **adapter** answered; the **car** hasn't yet |
| **LIVE — vehicle data received N s ago** | The car answered and values were decoded (green) |
| No new data … stale | Nothing new for more than 3 s; old values shown in grey |
| Connection lost — reconnecting | The link dropped; retries with backoff (2, 4, 8, then every 15 s) |

### Option A: Bluetooth LE (try this first)

1. **Don't** pair the adapter in System Settings › Bluetooth.
2. In the app, choose **Bluetooth LE** and click **Scan**. Allow Bluetooth access if macOS asks.
3. Pick the adapter from the list. Look for a name like "Innova", "OBD", "OBDII", "RS2" or similar, with a strong signal. Then click **Connect**.
4. Open the **Adapter Log** tab. It lists every BLE service and characteristic the adapter offers and which pair the app chose.

How the app picks the BLE link: many ELM327 BLE adapters offer one "notify" characteristic for replies and one "write" characteristic for commands. The app tries a few commonly seen service UUIDs first (`FFF0`, `FFE0`, `18F0`, `E7810A71-…`), then any non-standard service that has both. **This is a guess, not documented Innova behavior.** If it picks the wrong pair, the status will stay at "waiting for the adapter to reply" and the attempt will time out. It won't claim a connection.

### Option B: Bluetooth Classic (serial)

1. Open System Settings › Bluetooth, put the adapter in range, and pair it. If asked for a PIN, try `1234` or `0000`.
2. In the app, choose **Bluetooth Classic / Serial**, click ↻, and pick the adapter's `/dev/cu.*` port.
3. Click **Connect**.

Recent macOS versions don't always create a serial port for Classic Bluetooth devices. If no matching `/dev/cu.*` appears after pairing, use BLE.

### Option C: Wi-Fi adapters

Join the adapter's Wi-Fi network, then enter its IP address and port. `192.168.0.10:35000` is common, but check the adapter's manual. The Mac loses internet access while it's on the adapter's network; the app doesn't need internet.

---

## Permissions

| Permission | Why | Where to change |
|---|---|---|
| Bluetooth | Talk to a BLE adapter | System Settings › Privacy & Security › Bluetooth |
| Documents folder | Save CSV logs to `~/Documents/HermesOBD Logs/` | Prompted on first log, if needed |
| Network (Wi-Fi option only) | TCP connection to the adapter on your local network | No prompt, usually |
| Keychain | Stores the Hermes API key, if you set one | Keychain Access, item `local.hermesobd.monitor.hermes` |

The app doesn't use accounts or analytics. Vehicle data stays on your Mac unless you turn on [Hermes analysis](#hermes-agent-analysis), which sends summaries to your Hermes Agent and its configured model.

The app is ad-hoc signed for local use. If macOS blocks it, right-click › Open the first time.

---

## What the app shows

**Live Data** (standard SAE J1979 service 01 values; all are decoded in metric, then converted for display):

| Value | PID | US units | Metric |
|---|---|---|---|
| Engine RPM | 0C | rpm | rpm |
| Vehicle speed | 0D | mph | km/h |
| Coolant temperature | 05 | °F | °C |
| Intake air temperature | 0F | °F | °C |
| Throttle position | 11 | % | % |
| Calculated engine load | 04 | % | % |
| Short-/long-term fuel trim, banks 1 and 2 | 06/07/08/09 | % | % |
| Mass air flow | 10 | g/s | g/s |
| Intake manifold pressure | 0B | psi | kPa |
| Timing advance | 0E | ° BTDC | ° BTDC |
| Fuel level | 2F | % | % |
| Control module voltage | 42 | V | V |
| Ambient air temperature | 46 | °F | °C |
| Barometric pressure | 33 | psi | kPa |
| Run time since start | 1F | s | s |

Plus the adapter's own battery-voltage reading (`ATRV`) in the status bar.

**Unsupported values:** the app asks the car which PIDs it supports (`0100`, `0120`, `0140`…) and only polls those. Values the car doesn't list show "Not supported by this vehicle". A listed value that answers NO DATA three times in a row shows "Vehicle gave no data — treated as unsupported" and stops being polled. A 2005 car will likely not support some newer PIDs, such as ambient temperature or module voltage.

**Polling:** fast-changing values (RPM, speed, throttle, load, short-term trims, MAF, timing) are read every cycle. Slow values (temperatures, long-term trims, fuel level, pressures) are read every 5th cycle. Expect a few updates per second on a real adapter; the exact rate depends on the adapter and the car's bus speed.

**Trouble Codes:** **Read Trouble Codes** reports:
- check-engine light state and the code count the ECU reports (PID 01)
- stored codes (service 03)
- pending codes (service 07)
- permanent codes (service 0A; many older cars don't support this, and the app says so)

Generic descriptions are included for some common P0 codes. Ford-specific P1 codes show the code only.

**Adapter Log:** status notes and raw adapter traffic (`>` sent, `<` received), with Copy. This is the most useful thing to send when asking for help with a new adapter.

---

## Safety and read-only design

- **Every command goes through an allowlist** (`Sources/OBDCore/ReadOnlyGuard.swift`) before reaching any transport. Allowed:
  - OBD services `01` (live data), `03`, `07`, `0A` (trouble codes), and `09` (vehicle info)
  - adapter commands that don't save settings: `ATZ`, `ATE0`, `ATL0`, `ATS1`, `ATH0`, `ATI`, `AT@1`, `ATRV`, `ATDP`, `ATDPN`, and similar
- **Allowed only through the clear-codes flow:** service `04` (clear codes / reset monitors). It needs a one-time permit that only the engine's clear flow can create, after its safety checks pass. See [Clearing trouble codes](#clearing-trouble-codes).
- **Always refused, with an explicit error, even during a clear:**
  - `08` (actuator control)
  - `2E`/`2F`/`31`/`3B`/`3D`/`34`/`36` (write/control/reflash)
  - `10`/`11`/`14`/`27`
  - adapter commands that write adapter memory or change bus behavior (`ATSP`, `ATPP`, `ATSD`, `AT@3`, `ATMA`, `ATBRD`…)
  - anything containing a line break
  - anything else not on the list
- **No tuning, no reflashing, no actuator tests.** Clearing codes is the only write the app can do.
- The app does not set the protocol with `ATSP`, because that saves to the adapter's memory. It relies on the adapter's default automatic protocol detection.
- **"LIVE" requires real vehicle data.** It appears only after the car answers the supported-PIDs request *and* at least one value decodes. Adapter replies alone show as "Adapter replied — waiting for the vehicle".
- **Simulated data can't pass as real data.** It is labeled in the UI, the CSV file name, the CSV header, and each CSV row. If the simulator is served over TCP or serial for testing, the app detects that from the adapter's ID string and still labels it SIMULATED.
- **Don't use the screen while driving.** Have a passenger watch it, or log to CSV and review later.

---

## Clearing trouble codes

This is off by default and can't happen by accident. To clear codes:

1. Connect and wait for live data.
2. On **Trouble Codes**, click **Read Trouble Codes**. The app won't clear codes you haven't seen in this session.
3. Turn the engine **off**, leave the ignition **ON**, and keep the car parked.
4. Turn on **Allow clearing trouble codes** and click **Clear Codes…**.
5. Read the warning, type `CLEAR`, and click **Clear Codes**. Cancel is the default button.

What the app does next:
- **Reads the codes again** and records what's about to be erased.
- **Re-checks speed and RPM right before sending.** It refuses, sending nothing, if the car is moving, if RPM is 100 or more, or if either value can't be read.
- **Sends exactly one `04` command.**
- **Re-reads the codes after about 1.5 s** and shows the result:
  - confirmed by the ECU
  - refused by the app (nothing sent)
  - rejected by the ECU (for example "conditions not correct", which usually means the engine is running)
  - unconfirmed
- **Turns the switch back off.** Each clear needs a new opt-in, and the switch is also off at every launch.
- **Appends a line to `~/Documents/HermesOBD Logs/clear-history.log`.** It records the time, LIVE or SIMULATED, the outcome, RPM and speed, and the codes before and after. The erased codes stay on record.

What clearing does to the car:
- **Turns off the check-engine light and erases freeze-frame data.**
- **Resets the emissions readiness monitors.** The car will fail an emissions or OBD inspection until it has been driven through enough drive cycles for the monitors to complete. This usually takes several days of normal driving.
- **Fixes nothing.** If the fault is still there, the codes come back. Read and note the codes (or ask Hermes) before clearing.

In the simulator, untick **Simulated engine running** to test a successful clear.

### Performance tuning: not supported

The app doesn't tune or reflash the engine computer, and this won't be added:
- **Unreliable link:** reflashing a 2005 Mustang's PCM over a generic Bluetooth adapter is unreliable. A dropped connection mid-flash can leave the car unable to start.
- **Proprietary data:** it needs Ford's security access and calibration data specific to your car's software version.
- **Emissions rules:** changing emissions-related calibration on a road car is generally prohibited unless the tune is certified.

For tuning, use a dedicated handheld tuner made for 2005–2010 Mustangs, preferably with a CARB-certified (emissions-legal) tune. This app can log data before and after, for comparison.

---

## CSV logging

**Start Logging to CSV** becomes available once data is flowing. Files go to `~/Documents/HermesOBD Logs/obd_YYYY-MM-DD_HHMMSS.csv`, with `_SIMULATED` added for simulator sessions. **Show Last Log in Finder** reveals the file.

Format:

```
# HermesOBD log. data_source=LIVE vehicle data adapter=ELM327 v1.5
timestamp,elapsed_s,data_source,engine_rpm (rpm),vehicle_speed (mph),coolant_temp (°F),...
2026-10-22T13:35:12.932Z,0.029,LIVE,680,0,179,...
```

- There is one row per polling cycle.
- A blank cell means the value wasn't read in that cycle: it's a slow value, unsupported, or failed. The app never fills in old or invented values.
- Units follow the app's unit setting at the time logging starts. The unit setting is locked while logging.
- Logging stops automatically when you disconnect.

---

## Hermes Agent analysis

The app can send your data to your local **Hermes Agent** (`~/.hermes/hermes-agent`) through Hermes's built-in OpenAI-compatible API server. You get a running commentary in the **Hermes Analysis** tab, and you can ask questions about the current data.

**How it works:**
- While data is live, the app collects readings for one interval (15 s to 5 min, default 30 s).
- At the end of each interval it sends Hermes a short text summary (`POST /v1/responses`). The summary has:
  - latest, min, average and maximum for each value
  - which values the car doesn't support
  - the protocol and adapter voltage
  - the last trouble-code read, if any
- Requests are chained with `previous_response_id`, so Hermes can compare each window with earlier ones in the same session. A new connection starts a new Hermes conversation.
- Reading trouble codes triggers an immediate analysis.
- Each analysis has a **What was sent** section showing the exact text.

**Privacy:** requests don't set a model or provider, so **Hermes uses its own configured model**. If that's a cloud model, these summaries leave your Mac and go to that provider through Hermes. The VIN, location and personal details are not included. The feature is **off every time the app starts** and only runs while the switch is on.

**Tools:** Hermes's API server gives the agent its normal toolset, terminal included. The app's instructions tell Hermes to reply with text only and not run tools for these messages. That's a request to the model, not something the app can enforce. To enforce it, limit the tools Hermes allows for its `api_server` platform in Hermes's own config (see `platform_toolsets` in Hermes's configuration docs).

### Setup

1. Turn on Hermes's API server by adding these two lines to `~/.hermes/.env`. Use your own long random key.

   ```
   API_SERVER_ENABLED=true
   API_SERVER_KEY=pick-a-long-random-string
   ```

2. Start the Hermes gateway, which runs the API server:

   ```bash
   hermes gateway
   ```

   It should print `API server listening on http://127.0.0.1:8642`.
3. In the app, open **Hermes Analysis**:
   - Keep the URL `http://127.0.0.1:8642`.
   - Paste the key and click **Test connection**. The key is saved in your macOS Keychain.
4. Connect to the car (or the simulator), choose an interval, and turn on **Send data to Hermes for live analysis**.

Notes:
- **Back up `~/.hermes/.env`** before editing it.
- The gateway must be running (`hermes gateway run`) whenever you use the feature.
- **Rebuilding the app:** the app is ad-hoc signed, so after `./scripts/build-app.sh` macOS may ask whether it can read the Keychain item. Click **Always Allow**, or paste the key again.
- **"Install it now? [Y/n]" at gateway startup:** this asks about Hermes's optional `fal` image-generation package. The gateway and API server work without it. Type `n` if you don't want it; pressing Enter means yes.
- Hermes replies are AI commentary and can be wrong.
- Cloud-model replies can take several seconds. If Hermes is still answering when the next interval ends, the app waits for that reply and sends the next window after it.
- Long sessions with short intervals use more of your Hermes provider's quota.

### Testing without Hermes

`obd-cli` includes a mock Hermes server that returns canned replies and never contacts any model.

Start it:

```bash
.build/debug/obd-cli mock-hermes --port 8649 --key test-key
```

In another terminal, send simulator data to it:

```bash
HERMES_API_KEY=test-key .build/debug/obd-cli --sim --dtc --seconds 20 --hermes http://127.0.0.1:8649 --hermes-every 5
```

To use the real Hermes from the command line, run the second command with `--hermes http://127.0.0.1:8642` and your real key.

## Limitations

- **Hermes analysis has been tested with simulated data only** (Hermes Agent 0.22.2 with a cloud model). It hasn't been tested with data from a car.
- Tested with one adapter (Innova 3210RS) on one car. Other adapters may behave differently. See [Hardware checks still to do](#hardware-checks-still-to-do).
- BLE characteristic selection is a heuristic, and some adapters may need a specific pair.
- With adapter headers turned off (`ATH0`), replies from multiple control modules can't be told apart. For live data the app uses the first matching reply. For trouble codes it merges codes from all modules.
- Only standard OBD-II (SAE J1979) data is supported. There's no Ford-specific enhanced data (Mode 22), because that requires Ford-specific definitions.
- Each value is read with its own request, without batching several PIDs into one request.
- Freeze-frame data (service 02) and the VIN aren't shown.
- The code description table is small and generic.
- macOS 14+ only. Built and tested on macOS 27 (Apple silicon).

---

## Once you know the adapter model

1. **Find the model:** check the label on the adapter, the box, or RepairSolutions2's device/settings screen. An FCC ID on the label can be looked up at fcc.gov to see which radio type it uses.
2. **Check Innova's support pages for that model.** Look for "ELM327", "third-party apps", "Bluetooth LE" or "Bluetooth Classic", and any Mac mention. Note what's documented and what isn't.
3. **Try BLE first,** following the [BLE steps](#option-a-bluetooth-le-try-this-first) above. Then copy the **Adapter Log**. It shows:
   - the services and characteristics, with their properties
   - which pair the app chose
   - the adapter's replies to `ATZ` and `ATI`
4. **Read the log.** Look at what the adapter does after `ATZ`:
   - **It answers with something like "ELM327 v…" and the vehicle answers `0100`:** the adapter works. Add its name to the README.
   - **The link opens but `ATZ` times out:** the app probably chose the wrong characteristic pair. Add the adapter's service UUID to the front of `BLETransport.commonServiceUUIDs` in `Sources/OBDMonitor/BLETransport.swift`, or pin exact characteristic UUIDs there. Rebuild and retry.
   - **No service has both notify and write, or replies are binary and not ELM327 text:** the adapter probably uses a proprietary RepairSolutions2 protocol. It isn't supported, and the right move is a standard ELM327 BLE adapter.
   - **It works but some commands answer `?`:** check which ones in the log, and drop them from the init list in `OBDEngine.connectAndPoll`. Keep `ReadOnlyGuard` as strict as it is.
5. **If the adapter is Classic-only,** pair it and use the serial option.
6. **Any new adapter command must be read-only** (clear codes stays the only exception) and added explicitly to `ReadOnlyGuard.allowedATCommands`, with a test in `Tests/OBDCoreTests/SafetyTests.swift`.

---

## Testing

```bash
cd ~/Downloads/HermesOBD
swift build --build-tests -j 1 && swift test --skip-build     # 57 tests
```

The `-j 1` avoids an intermittent "plugin for module 'TestingMacros' not found" error seen with the Command Line Tools toolchain. Rerunning also clears it.

Headless tool:

```bash
swift build --product obd-cli
.build/debug/obd-cli --sim --seconds 10 --dtc --csv /tmp/sim.csv
.build/debug/obd-cli --sim --ignition-off --seconds 6    # should never report live data
```

The test suite covers:

- PID formulas, the supported-PID bitmap, and unit conversion
- ELM327 reply parsing: spaces on/off, `SEARCHING...`, error strings, multi-frame CAN, echo
- trouble-code decoding (CAN and non-CAN)
- the read-only allowlist, including proof that refused commands never reach the adapter and that a whole session sends only allowed commands
- clearing codes: refused without a permit; every other write refused even with one; nothing sent while the engine runs; success with the engine off; ECU rejection reported
- CSV format
- engine behavior against the simulator:
  - reaching LIVE
  - unsupported-PID detection
  - never going LIVE when the car is silent
  - trouble codes
  - recovery after a dropout
  - labeling a self-identified simulator as SIMULATED

You can also test the serial and Wi-Fi code paths without hardware by serving the simulator.

Serial:

```bash
.build/debug/obd-cli emulate --pty
```

It prints a `/dev/ttys…` path. Use that path with `--serial`, or in the app.

Wi-Fi (TCP):

```bash
.build/debug/obd-cli emulate --tcp 35000
```

Then connect to `127.0.0.1:35000`.

**UI self-check:** this runs the app against the simulator, saves PNGs of its own window (live data, trouble codes, adapter log, dropout, reconnect, disconnected), then quits. It also writes a `_SIMULATED` CSV to the logs folder.

```bash
OBD_SELFCHECK_DIR=/tmp/obd-shots "dist/HermesOBD.app/Contents/MacOS/OBDMonitor"
```

Add `OBD_SELFCHECK_CLEAR=1` to run the clear-codes check instead. It captures the confirmation dialog, a refusal with the engine running, and a confirmed clear with the engine off, all on the simulator. It writes SIMULATED lines to `clear-history.log`.

### Hardware checks still to do

- [x] Identify the adapter model (Innova 3210RS, BLE name `Dongle` + number)
- [x] BLE scan finds the adapter, and the Adapter Log lists its services
- [x] Adapter answers `ATZ`/`ATI` (ELM327 v1.3a)
- [x] With the engine running, the car answers `0100` and the status turns green LIVE
- [x] Protocol shown in the status bar (ISO 15765-4 CAN 11-bit/500k)
- [x] Values look plausible (idle RPM, coolant temperature, fuel trims)
- [x] Read trouble codes: none stored or pending, MIL off
- [ ] Unplug the adapter, or turn the ignition off, while connected → reconnecting, then recovery
- [ ] CSV log from a short drive (with a passenger watching the screen)
- [ ] Clearing codes on the car (only if there's ever a reason to)
- [ ] Hermes analysis with live car data

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Adapter not in the BLE list | It's paired with or connected to the phone. Quit RS2 or turn off the phone's Bluetooth, then unplug and replug the adapter. |
| "Bluetooth permission denied" | Allow it in System Settings › Privacy & Security › Bluetooth. Launch the `.app`, not `swift run`. |
| Stuck on "waiting for the adapter to reply", then times out | Wrong BLE characteristic pair, or a non-ELM327 adapter. See the Adapter Log and [Once you know the adapter model](#once-you-know-the-adapter-model). |
| "Adapter replied — waiting for the vehicle", then "vehicle did not respond" | Ignition off, the adapter isn't fully seated, or the adapter can't detect the protocol. |
| Many values say "Not supported" | Normal for an older car. Only PIDs the car lists are polled. |
| Values grey with "Stale" | No new data for more than 3 s. The link is slow or dropped, and a reconnect will follow. |

---

## Project layout

```
Package.swift
Sources/OBDCore/          protocol, decoding, safety guard, engine, simulator, serial/TCP transports, CSV, Hermes client
Sources/OBDMonitor/       SwiftUI app, Bluetooth LE transport, self-check
Sources/obd-cli/          headless monitor + simulator server
Tests/OBDCoreTests/       Swift Testing suite
Resources/Info.plist      app bundle metadata, including the Bluetooth usage text
scripts/build-app.sh      builds dist/HermesOBD.app
```

---

## License

[MIT](LICENSE). You're free to use, modify, and share this code, including commercially, as long as the copyright notice is kept.

This software talks to your car's computer. It comes with no warranty; use it at your own risk, and never use it in a way that distracts you while driving.
