# EDID Forcer

A macOS menu bar app that patches connected external displays' EDIDs on the fly,
using the DCP's virtual-EDID mechanism — a software-only override that is never
written to the monitor's own EEPROM and disappears the moment the app quits, the
display reconnects, or you hit reset.

**Apple Silicon Macs only.** The mechanism this app relies on (the DCP and its
`IOAVService` API) doesn't exist on Intel Macs — see [Requirements](#requirements).

## Features

Three independent, deterministic patches, each applied to every connected
external display at once:

- **Force 8-bit Color** — declares 8 bits per component in the EDID's Video
  Input Definition byte, overriding displays that default to a higher bit depth
  (commonly 10 or 12, often via FRC) that some GPU/driver/cable combinations
  negotiate unreliably. Use this if an external display shows color banding,
  flickering, or dropped frames that clear up when the OS is forced to treat it
  as an 8-bit panel instead of negotiating a higher depth the link can't sustain
  cleanly.
- **Strip HDR Metadata** — removes the CTA-861.3 HDR Static Metadata Data Block,
  so the display reports as SDR-only. Use this on a display whose HDR mode
  macOS keeps auto-switching into (often with washed-out colors or a jarring
  brightness jump), when you'd rather it just never comes up.
- **Strip VRR Signaling** — truncates the HDMI Forum Vendor-Specific Data Block
  to its pre-HDMI-2.1 baseline, dropping VRR/ALLM/QMS signaling. Use this if an
  HDMI-connected display's variable refresh rate causes visible flicker or
  brightness pulsing under macOS. Only affects HDMI-connected displays; over
  DisplayPort, VRR is negotiated via DPCD rather than the EDID, so this patch
  has no effect there.

The menu bar shows one line per connected display with a status indicator per
feature:

| Symbol | Meaning |
|---|---|
| ✓ (green) | Enabled, and confirmed on the live display |
| ○ (blue) | Enabled, but nothing to change — the targeted EDID structure doesn't exist on this display |
| ✗ (red) | Enabled, but not confirmed |
| – (grey) | Not enabled |

Settings persist across launches and re-apply automatically, so the app works
unattended if added to Login Items.

## How it works

Each external display's DCP (Display Co-Processor) exposes a `DCPAVServiceProxy`
in the IORegistry. The private `IOAVService` API (real, exported symbols in
`IOKit.framework`, but undocumented) lets a signed process read a display's
current EDID and override it in memory via `IOAVServiceSetVirtualEDIDMode` — the
DCP serves the override instead of the real EDID until the process exits, the
cable is unplugged and replugged, or the override is explicitly reset.

`EDIDPatcher` applies each enabled patch to a cached copy of the display's real
EDID, recomputing only the checksum(s) each patch affects, so any combination of
patches composes safely into one EDID. The result is compared against what the
display is currently presenting, and only written if it differs — this makes it
safe to re-run on every display reconfiguration event without causing a
retrain/flicker feedback loop.

## Requirements

- **Apple Silicon only.** The DCP/IOAVService mechanism this app relies on
  doesn't exist on Intel Macs; the app is built `arm64`-only and won't launch
  under Rosetta.
- **macOS 13 (Ventura) or later.**
- **Code signing with a certificate that chains to Apple.** A free Personal Team
  "Apple Development" certificate is sufficient; ad-hoc signing (`codesign -s -`)
  is not — `IOAVServiceCreateWithService` will fail to open the service otherwise.
- **App Sandbox off**, under Signing & Capabilities.

## Building

Open `EDIDForcer.xcodeproj` in Xcode, set your own signing team if needed, and
build/run. There's no external dependencies.

## Limitations

- Relies on undocumented, private IOKit symbols (`IOAVServiceCreateWithService`,
  `IOAVServiceCopyEDID`, `IOAVServiceSetVirtualEDIDMode`) and IORegistry class
  names (`DCPAVServiceProxy`, `IOMobileFramebufferAP`). Apple can change or
  remove any of these without notice in a future macOS release.
- Strip HDR/VRR verification reads the display's live EDID back directly, since
  there's no equivalent "negotiated state" signal available for those in the
  IORegistry the way there is for color depth.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or
[MIT license](LICENSE-MIT) at your option.
