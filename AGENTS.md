# iHypnusCare: agent notes

A read-only reader and report app for **Hypnus Series 8** CPAP SD cards (tested on a CA820W APAP, firmware V1.08). If `AGENTS.local.md` exists, read it too. It holds the user's private machine details and is gitignored.

## Ground rules

- **SD cards are read-only.** Never write, rename or touch a card's files (or a copy of one). `tools/hypnus_report.py` only reads, and refuses to write output inside the card folder.
- Never generate fabricated or synthetic therapy data, or reports that look like real compliance records.
- Never commit personal data: generated reports (`Reports/`), card copies, real serial numbers or health figures. README screenshots use **Hide serial number** and no patient name.
- OSCAR does not support Hypnus machines, and Hypnus publishes no format spec. Everything below was worked out from a real card and the user manual. It was then confirmed against Hypnus' own Windows viewer (`NSE-BMSys.exe`, .NET, shipped on the card as `Hypnus 8S/portable hypnus pc software.zip`), decompiled with ILSpy: parser `NSE_BMSys.EDFFile.EdfFileStruct/EdfFileHelper.cs`, summary maths `NSE_BMSys.EDFFile/SummaryData.cs`. No Hypnus code is in this repo.

## Layout

| Path | What |
|---|---|
| `tools/hypnus_report.py` | Read-only reader (Python 3 stdlib). Text summary, or `--html OUT [--open] [--progress]` for the full report. `--progress` prints one JSON line per folder (`done`, `total`, `folder`, `files`) for the app. Paths under the home folder are written as `~/…` |
| `tools/report_template.html` | Report UI (light mode only). The script injects JSON at `/*__DATA__*/null`. Inside the app (`window.webkit.messageHandlers.cpap` exists), the PDF goes to the app as base64 instead of a browser download, and `window.cpapExportPdf()` is exposed for the app's menu and toolbar. **Hide serial number** (stored in localStorage) masks the serial as `XXXX-XXX` on screen and in the PDF |
| `tools/assets/` | `hypnus-logo.png` (transparent), `device.jpg`, `app-icon.png` |
| `tools/app/` | `iHypnusCare.swift` (AppKit + WKWebView, no Xcode project) and `build_app.sh`. The build compiles a **universal** binary: arm64 for macOS 11+ and x86_64 for macOS **10.14.4+**, the first macOS with Swift built in (the app can't bundle a Swift runtime). It passes `-runtime-compatibility-version none` because current Command Line Tools ship the Swift back-deployment shim libraries for arm64 only; without that flag, x86_64 builds below macOS 13 fail to link. The app uses nothing that needs the shims. APIs newer than 10.14.4 (SF Symbols, `toolbarStyle`, `.large` controls, toolbar `isBordered`) are behind `#available` with fallbacks, and the Save panel uses `allowedFileTypes`. The version is set at the top of `build_app.sh`. The build then bundles the reader, template and assets into `Contents/Resources/tools`, signs ad hoc in a temp dir (codesign rejects bundles on SMB shares), then copies the result to `iHypnusCare.app` (gitignored). Re-run it after changing the Swift, reader or template |
| `tools/win/` | **Windows app**: `ihypnuscare_win.py` (pywebview, runs the reader in-process on a thread) + `ui.html` (welcome and progress screens, which talk to Python via `window.pywebview.api`). Progress uses `window.evaluate_js` (throttled to about 12/s). The report loads in the same window. `save_pdf(name, b64)` shows a Save dialog and returns a status string. Settings and `log.txt` go in `%LOCALAPPDATA%\iHypnusCare`; the report is written beside `ui.html` (the `_MEIPASS` temp folder), because pywebview's local server only serves the start page's folder (anything else returns 404). A folder passed as `argv[1]` (dropped on the exe) is read at start. Also runs on macOS for development (`pip install pywebview`) |
| `.github/workflows/windows.yml` | Manually run (`gh workflow run windows.yml -f tag=v1.10 [-f attach=true]`). On `windows-latest` with Python 3.12, it pins pywebview 5.3.2, PyInstaller 6.11.1 and Pillow 11.0.0 (Pillow makes the .ico), and builds a one-file `--windowed` x64 `iHypnusCare.exe`. `report_template.html`, `ui.html` and the assets go to the `_MEIPASS` root and `assets/`. It uploads an artifact, and with `attach` it also uploads `iHypnusCare-<tag>-Windows-x64.zip` to the release |
| `docs/screenshots/` | README images |

The app shows a welcome screen, then "Open SD Card or Folder…" (or a folder dropped on the window or Dock icon), then a progress bar with folder and file counters, then the report in a WKWebView. Toolbar/menu: Open… (⌘O), Export PDF (⌘E, opens a Save dialog). It runs the first Python 3 it finds: python.org framework, Homebrew (`/opt/homebrew`, `/usr/local`), MacPorts, then `/usr/bin/python3` (Apple's Command Line Tools on 10.15+; absent on Mojave). The reader needs Python 3.8+ (walrus operator). When the Intel slice runs under Rosetta, it launches Python through `/usr/bin/arch -arm64 -x86_64`, because otherwise the child process inherits x86_64 and arm64-only Command Line Tools fail with an `xcrun`/`libxcrun` error. The report page finds its host with `nativeHost()` at use time: the WKWebView `cpap` message handler, or `window.pywebview.api` (which only appears after `pywebviewready`, so it re-checks on that event and then shows "Export PDF…" and "Open another card…"). The report script is kept to **ES2019** (no `?.`/`??`) with a `replaceChildren` polyfill, so older WebKit on 10.14/10.15 can run it. Check with `npx acorn --ecma2019`. It writes the report to `~/Library/Caches/local.ihypnuscare/report.html`. The About box and PDFs say it is unofficial and not made by Hypnus.

Commands (`<card>` = the SD card, e.g. `/Volumes/NO NAME`, its `DATAFILE` folder, or a folder holding a copy):
```
python3 -I tools/hypnus_report.py <card> --days 30 --nights        # text summary
python3 -I tools/hypnus_report.py <card> --html report.html --open # full report in the browser
tools/app/build_app.sh                                             # build iHypnusCare.app
```

The report has range presets (7, 30 and 90 days, 6 months, 1 year, All) and custom from/to dates. It shows compliance, AHI breakdown, settings, pressure and leak percentiles, breathing stats, 4 trend charts (daily, then weekly over 120 days, then monthly over 730), a per-night detail chart and a nightly table. **PDF export** builds a vector PDF with jsPDF 2.5.1, jspdf-autotable 3.8.2 and svg2pdf.js 2.2.3. These load from cdnjs/jsdelivr on first use, so export needs internet. Patient name and DOB are kept only in the page's localStorage.

## Card layout

```
<card>/
  DATAFILE/YYYYMMDD/YYYYMMDD_<kind>.edf   one folder per therapy start date (device local time)
  CONFIG/config.bin                       192-byte settings blob, first byte 0xBB = Series 8
  log.txt                                 firmware log (power on/off, hour meters, WiFi)
  resend.hex                              WiFi (Aliyun cloud) upload queue
  Hypnus 8S/                              factory extras: manual PDF, quick start guide, Windows viewer zip
```

Folder date = device-local date the session **started**. Reports group nights noon to noon (start time minus 12 h), so a 00:58 start belongs to the previous evening. The Hypnus viewer groups by the session's calendar start date instead.

## File format ("EDF-like", not standard EDF)

Every `.edf` file has a **512-byte ASCII header** (`ReadHeader`): version(8) e.g. `V1.08`, patient(80, serial embedded), recording(80, `8C` = Series 8), then **binary** first/last start timestamps (8+8), header bytes(8) `512`, reserved(44) e.g. `V1.08-10007 hypnus CA820W`, record count(8), **DataCycle(8) = sample period in ms**, signal count(4), label(16), and so on.

**Timestamp (8 bytes):** `u16 year, u8 month, u8 day, u8 weekday, u8 hour, u8 min, u8 sec`, in device local time. `log.txt` shows the same local times with a misleading `Z` suffix.

### Event and usage files: 16-byte records after the header

| File | Record | Meaning |
|---|---|---|
| `_ai.edf` | u32 count=1, u32 duration s, ts | obstructive/unclassified **apnea** |
| `_hi.edf` | same | **hypopnea** |
| `_csa.edf` | same | **central apnea** (never overlaps `ai`) |
| `_csr.edf` | same, duration = CSR episode length | Cheyne-Stokes. The viewer reports total minutes |
| `_pb.edf`, `_fl.edf` | same | periodic breathing, flow limitation |
| `_snore.edf` | u32 count, u32 snore level, ts | snore events |
| `_leak.edf` | u32 leak volume, u32 duration s, ts | large-leak episodes |
| `_usetime.edf` | u32 **therapy seconds**, u8 **mode**, u8 p1, u8 p2, u8 p3 (x0.1 cmH2O; APAP: p1 = max, p2 = min), ts = **stop time** | one record per session |
| `_apcp.edf` | u32 APAP pressure x0.1, u32 EPAP x0.1, ts | once a minute. Sometimes missing |
| `_config.edf` | 192-byte settings blob + 8-byte ts | one record per power-on or settings change |

Mode enum: 0 CPAP, 1 APAP, 2 BPAP-S, 3 AutoBPAP-S, 4 BPAP-T, 5 BPAP-ST, 6 ASV, 7 AutoASV.

### Continuous signals: sessions concatenated in usetime order, no timestamps

| File | Period | Sample | Meaning |
|---|---|---|---|
| `_pressure.edf` | 80 ms | i16 x0.1 cmH2O | set/target pressure (ignore < 3.0, blower spin-up) |
| `_realpresdata.edf` | 80 ms | i16 x0.1 | measured mask pressure |
| `_flow.edf` | 80 ms | u8 | flow waveform |
| `_snoredata.edf` | 80 ms | i16 | estimated flow / snore waveform |
| `_difleak.edf` | 5 s | u8 L/min | **unintentional leak** |
| `_mvtvbr.edf` | 10 s | u16 tidal volume mL, u16 breath rate /min, u16 inspiratory time ms | MV = TV x RR |
| `_spo2bpm.edf` | 1 s | u8 SpO2 %, u8 pulse | zero unless an oximeter is attached |

Each session takes `secs / period` samples (pressure and flow match exactly, the slower signals round down per session).

### Settings blob (192 bytes, `ReadConfig8`)

Byte 0 `0xBB`. Byte 6 mask (0 nasal, 1 full face, 2 pillows), 7/8 SmartStart/SmartStop. **32 i16 LCD report period** (0 = 1 day … 3 = 1 month … 6 = 1 year), **34 i16 days used**, **36 i16 days 4h+**. **40.. f32 x10: 90% pressure (insp/exp), leak, AHI, AI, HI, CSA, CSR, PB, snore.** 96 mode, 97 ramp min, 98 humidity level, 99 heated-tube °C, 100/101 exhale-relief (DEP) type/level. 112.. f32 x14: CPAP, APAP max, APAP min, BPAP IPAP/EPAP, AutoS max/min/PS, start pressure, … 184/185 fw version, 186 model code (51–62: CA820M/W/–, BA825M/W/–, ST830M/W/–, AU830Pro, SV825W/M).

## How the numbers are calculated

- **AHI (report)** = (ai + hi + csa) / usage hours. **Hypnus' screen and viewer use AI + HI only** and list CSA separately. The report shows both.
- Usage hours = sum of `usetime` seconds. A "4h day" in the report = total ≥ 4 h per night. **The machine's screen counts only days with one unbroken session ≥ 4 h**, so its count can be lower.
- Pressure percentiles come from `pressure.edf` at about 1 Hz (pooled histogram). Leak percentiles come from all `difleak` samples (Hypnus' viewer excludes zeros for its 50%/90% leak). Large leak = above 24 L/min.
- Range stats pool the per-night histograms, so the percentiles are exact. Breathing values are hours-weighted means of nightly medians.

## Where the machine's LCD stats come from

- Manual §3.1.6: Info shows 1 day to 1 year reports, and "the data is recorded via an SD card". The firmware computes them from the card. It polls the EDF files every minute while running (`edf lseek` log lines).
- When the Info screen is viewed, the result is **written back** into `CONFIG/config.bin` and a new `config.edf` record (offsets 32–80 above). These values matched the decoded card data when checked.
- Internal memory holds settings plus the **Device Time / Motor Time** hour meters (`stop Device Time:…h Motor Time:…h` in `log.txt`). Motor hours between two log lines = summed usetime. That's the best completeness check for gaps in the card data.
