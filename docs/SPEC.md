# Lucent: behaviour spec

Each feature, how it behaves, and the macOS API behind it. Every feature is free.

## 1. Features and APIs

| Feature | Behaviour | API |
|---|---|---|
| Display list | Online displays, built-in first, then external, then virtual. Updates on every reconfiguration. | `CGGetOnlineDisplayList`, `CGDisplayRegisterReconfigurationCallback` |
| Resolution | Every mode, including duplicate low-resolution ones. One entry per size and scale. Favourites are cycled with ⌃⌥← / →. | `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes`, `CGConfigureDisplayWithDisplayMode` |
| Refresh rate | Rates offered at the current size. | same |
| Notch | Switches between the full-height and letterboxed version of the same width. | mode list |
| Flexible HiDPI | Creates a HiDPI virtual screen at the panel's pixel size and mirrors the real display onto it. The resolution list then shows the virtual screen's modes. | `CGVirtualDisplay`, `CGConfigureDisplayMirrorOfDisplay` |
| Rotation | 0/90/180/270. | `MPDisplay setOrientation:` (MonitorPanel, private) |
| Main display / arrangement | Drag to arrange, with snapping to the nearest edge. | `CGConfigureDisplayOrigin` |
| Mirroring | Mirror all, or one display of another. | `CGConfigureDisplayMirrorOfDisplay` |
| Brightness: native | Built-in and Apple displays. | `DisplayServicesGet/SetBrightness` (private) |
| Brightness: DDC | VCP 0x10 over I²C. Writes are coalesced while dragging. | `IOAVServiceWriteI2C/ReadI2C` (private), DCPAVServiceProxy matched to the display by vendor/product/serial |
| Brightness: software | Gamma-table multiplier. | `CGSetDisplayTransferByTable` |
| Dim to Black | The bottom 15% of the combined slider is software dimming below the hardware minimum. | gamma |
| XDR Boost | A click-through, screen-saver-level Metal window clears to EDR grey > 1.0 with a multiply blend. Capped at 3.2× (about 1600 nits). | `CAMetalLayer.wantsExtendedDynamicRangeContent`, `compositingFilter = multiplyBlendMode` |
| Image adjustments | Contrast, gamma, Kelvin temperature, RGB gains and invert, combined into one 256-entry table with the dim factor. | `CGSetDisplayTransferByTable` |
| DDC controls | Contrast 0x12, volume 0x62, mute 0x8D, input 0x60, power 0xD6 (standby = 4). | IOAVService |
| Colour profile | Any installed ICC profile. | `ColorSyncDeviceSetCustomProfiles` |
| XDR presets | Reference modes on Apple XDR and Studio displays. | `MPDisplay presets / setActivePreset:` (private) |
| Night Shift | System Night Shift on and off. | `CBBlueLightClient` (CoreBrightness, private) |
| Anti-PWM | Turns off temporal dithering on the framebuffer when the Mac allows it. | `IORegistryEntrySetCFProperty("enableDither")` |
| Disconnect / reconnect | Switches a display off without unplugging it. Lucent remembers what it switched off and turns it back on at quit. | `CGSConfigureDisplayEnabled` (SkyLight, private) |
| Connection rules | Turn off built-in with external; reconnect on wake; keep only one display on. | the above + `NSWorkspace.didWakeNotification` |
| Protection | Saves mode, origin, rotation and profile per display, and restores them 1.5 s after a reconfiguration if any changed. | reconfiguration callback |
| Virtual screens | Any size with a ladder of scaled modes. HiDPI, 30/60/120 Hz. Connect at login. Stable serials so names survive relaunches. | `CGVirtualDisplay` (CoreGraphics, private) |
| Groups | Sync brightness (optionally in nits from each display's peak) and image adjustments. | — |
| Auto brightness | External displays follow the built-in ambient-light brightness. | polling `DisplayServicesGetBrightness` |
| Brightness keys | Intercepts brightness keys only when the pointer is over a display macOS can't dim itself. | `CGEventTap` on system-defined events (needs Accessibility) |
| Shortcuts | ⌃⌥↑↓ brightness, ⌃⌥←→ resolution, ⌃⌥=/− volume, ⌃⌥R reconnect, ⌃⌥P PiP. | Carbon `RegisterEventHotKey` |
| OSD | Modern (glass capsule) or classic. Broadcast to other apps as `com.yahyakhamaisi.lucent.osd`. | `NSPanel`, `DistributedNotificationCenter` |
| PiP / streaming | Display or window capture, excluding Lucent's own windows. Flip, rotate, sharpen, `.cube` LUT, fps, opacity, click-through, hide from capture, full-screen streaming to another display. | ScreenCaptureKit, `CALayer.filters` with Core Image |
| TVs | SSDP discovery, then LG SSAP over WSS 3001 (pairing prompt, client key saved), Samsung remote channel over WSS 8002 (token saved), Philips JointSpace v1, Yamaha YXC. | `URLSessionWebSocketTask`, UDP sockets |
| CLI | `lucent …` is a shell shim that runs `Lucent cli …`, which forwards to the running app and prints the reply. | `DistributedNotificationCenter` |
| URL scheme | `lucent://<command>?<option>=<value>`. | `kAEGetURL` |
| HTTP | `127.0.0.1:<port>/<command>?…`, plain-text reply. Local only. | `NWListener` |
| Shortcuts | Set/Get Brightness, Set Resolution, Set XDR Boost, Connect Virtual Screen, Disconnect Display, Run Command. | App Intents |
| Event scripts | Per display: on connect, disconnect, sleep and wake. Each is a shell command, a `lucent …` command or `shortcut: Name`. | `Process`, `shortcuts run` |
| EDID | Read from the IORegistry, then export. Overrides go to `/Library/Displays/.../Overrides` (name, scale-resolutions, IODisplayEDID) with an admin prompt. | IOKit, `NSAppleScript` |
| Diagnostics | Mode, pixels, refresh, EDR headroom, vendor/product/serial, DDC status, EDID, console with command input. | — |

## 2. Known limits

- Apple silicon only for DDC. Intel Macs keep native and software brightness.
- HDMI-CEC isn't implemented. Lucent controls TVs over the network instead.
- Colour encoding (RGB/YCbCr, range, chroma) has no public or stable private setter on Apple silicon, so Lucent doesn't change it.
- Apple silicon honours fewer display-override keys than Intel. Flexible HiDPI is the dependable way to get custom HiDPI sizes there.
- Builds are signed ad hoc, so macOS asks again for Accessibility and Screen Recording after each rebuild.
