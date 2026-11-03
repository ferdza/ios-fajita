# Connectivity research — Wi-Fi, Bluetooth, USB

Research notes (no implementation yet) for bringing up the OnePlus 6T's
connectivity under this XNU + iOS-userland port. Goal: understand the hardware,
the reference drivers, the realistic path on XNU, and a sensible priority order.

State as of **2026-11-03**. Observations and assumptions are kept distinct;
hardware facts carry a source.

---

## Update 2026-11-03 — three findings that reshape the plan

1. **On-SoC Wi-Fi is gated on the whole modem/remoteproc stack, confirmed.** On
   SDM845, WCN3990 Wi-Fi is a **QMI client of the modem (mpss)**: `wlanmdsp.mbn`
   loads into the modem subsystem (backed by the `wlan-msa` reserved region at
   `0x8df00000`). With the modem remoteproc disabled, `ath10k_snoc` loads and the
   service reports "loaded", **but `wlan0` never appears** — there is no
   `remoteproc` to serve WLAN QMI. Bringing up Wi-Fi therefore means first
   standing up `pd-mapper` + `tqftpserv` + `rmtfs` + the modem remoteproc and
   waiting for the QMI service — a prerequisite milestone in its own right.
   ([OnePlus 6T Linux boot log](https://github.com/ToniMcQueen/oneplus6t-install-linux-Arch-on-arm-845/issues/1),
   [SDM845 ADSP/CDSP remoteproc patch](https://lore.kernel.org/lkml/20180828071458.26858-1-bjorn.andersson@linaro.org/))

2. **Even the best XNU-Qualcomm-Wi-Fi project isn't fully native yet.** Snapintosh
   ships a *native IO80211 QCC2072 driver* and its README states Wi-Fi only does
   "scan, WPA2, DHCP, ping **through a host-proxy harness** driven from the Mac —
   joining from the macOS Wi-Fi menu does not work yet." A reality check on how
   hard the native IO80211 join path is.
   ([Snapintosh repo](https://github.com/Snapintosh/Snapintosh),
   [PR #12 PM/roaming, closed unconnected](https://github.com/Snapintosh/Snapintosh/pull/12))

3. **There is a kext-free data path we already half-own: `utun`.** A macOS Wi-Fi
   project for an RTL8852B USB dongle (`rtw89-macos-tun`) uses **no kext and a
   `utun` data path** instead of touching the closed IO80211Family. Our existing
   CDC-ECM patch (`0075`) already drives a BSD network interface via
   `net/kpi_interface.h` — the same shape. This makes a **USB-dongle + userland
   driver → `utun`** path the lowest-risk way to get real internet without either
   the modem stack *or* the closed Apple 802.11 stack.
   ([rtw89-macos-tun](https://github.com/Long0823-1/rtw89-macos-tun/releases))

Net effect on priorities (details below): the ranking stands, but the pragmatic
near-term internet path is **USB host → USB Wi-Fi/Ethernet dongle → `utun`**, and
the native WCN3990 Wi-Fi is explicitly a two-stage effort (modem/QMI first, then
the ath10k-class driver + IO80211 glue).

---

## Hardware inventory (fajita / SDM845)

| Function | Chip | Transport | Linux driver | Firmware |
| --- | --- | --- | --- | --- |
| Wi-Fi | **WCN3990** (combo) | SNoC (on-SoC, not PCIe) | `ath10k_snoc` + QMI/`wlfw` | `WCN3990/hw1.0/` firmware + `board-2.bin` calibration variant `oneplus_sdm845` |
| Bluetooth | **WCN3990** (same combo) | UART (+ power sequencing) | `hci_qca` / `btqca` | `qca/crbtfw*.bin`, `qca/crnv21.bin` (per-device NVM) |
| USB | SDM845 **DWC3** (dwc3-qcom) | — | `dwc3` + `dwc3-qcom` | none (controller); PHYs QUSB2 (HS) + QMP (USB/DP combo) |

Sources: ath10k-firmware board file "WCN3990: Add board file for OnePlus 6/6T"
and the `qcom,calibration-variant = oneplus_sdm845` DTS work; `hci_qca`/`btqca`
WCN39xx power-sequencing patches and the Kali NetHunter report naming
`qca/oneplus6/crnv21.bin`; the 2018 SDM845 USB PHY/dwc3 bring-up series. See the
links section.

Key hardware notes:
- **Wi-Fi depends on the ADSP/modem remoteproc.** `ath10k_snoc` reaches the WLAN
  firmware through **QMI** (the `wlfw` service), which is only up once the modem
  or ADSP remoteproc is running. On Linux there is even a documented probe-order
  race (WLAN probes before the modem is ready). So Wi-Fi is not standalone: it
  needs remoteproc + QMI first.
- **USB host mode is PMIC/VBUS-dependent.** The SDM845 Type-C port can do host,
  but it needs the PMIC/VBUS configured (historically done by the bootloader) and
  Type-C role detection. Our current use is device mode only.

## What we already have

**USB device mode + CDC-ECM networking works today** — patches `0072-sweet-usb-probe`,
`0073-sweet-usb-device-ep0`, `0074-sweet-usb-vbus-override`, `0075-sweet-usb-ecm`,
`0076-sweet-usb-rx-mbuf`, `0077-sweet-usb-live-log`. The phone appears to the host
PC as a USB Ethernet device (host `192.168.7.1`, phone `192.168.7.2`) and streams
the live kernel console over UDP (`tools/sweet-usbnet.sh`). So we have a working
DWC3 **device-mode** driver and a CDC-ECM gadget.

Nothing exists yet for Wi-Fi, Bluetooth, or USB **host** mode.

## The XNU reality

There is no Linux `mac80211`, BlueZ, or Linux USB core here. On XNU, each stack
has an Apple-shaped home:
- Wi-Fi → **IO80211Family** + **Skywalk** (the networking datapath).
- Bluetooth → **IOBluetoothFamily** (large, closed).
- USB host → **IOUSBHostFamily**.

So a driver has to do both halves: the **chip bring-up** (Qualcomm protocols) and
the **Apple-side glue** (IO80211 / HCI transport / IOUSBHost). We also run a
permissive, cut-down XNU, so parts of these families may be absent or stubbed and
need standing up.

Two things sharpen this:

- **Apple's 802.11 stack is a moving, closed target.** Since iOS 13 / macOS 10.15
  it is *IO80211FamilyV2* (then the suffix was dropped again), layered as
  daemons (`airportd`) → `CoreWLAN`/`Apple80211` → `IO80211Family` +
  `IOSkywalkFamily` (the datapath) → plug-in driver → bus driver. The headers are
  not shipped; projects regenerate `IO80211Controller` etc. from binaries. Writing
  a real `IO80211Controller` subclass means reverse-engineering that contract.
  ([Black Hat 2020 IO80211FamilyV2](https://i.blackhat.com/USA-20/Thursday/us-20-Wang-Dive-into-Apple-IO80211FamilyV2.pdf),
  [acidanthera MacKernelSDK PR #13 — Skywalk headers absent](https://github.com/acidanthera/MacKernelSDK/pull/13))
- **The escape hatch: skip IO80211 entirely with `utun`.** A userland driver can
  hand packets to a BSD `utun` interface and let the normal `bsd/netinet` stack
  route them — no IO80211, no Skywalk. We already do the IOKit-network-interface
  shape in the CDC-ECM gadget. The cost is no native Wi-Fi-menu UX (you configure
  the link yourself), which for a bring-up is fine.

---

## Stack 1 — USB (most tractable; partly done)

- **State:** device mode + CDC-ECM already working (above). The gap is **host
  mode** (attach USB peripherals) and USB 3 (QMP PHY / SuperSpeed).
- **Path:** extend the existing DWC3 driver to host (xHCI-style) mode, bring up
  the QMP PHY, and handle Type-C role + VBUS via the PMIC. Then a minimal
  IOUSBHost surface to enumerate devices.
- **Why it matters:** a USB-host path could reach a **USB Wi-Fi/BT/Ethernet
  dongle** — pragmatic connectivity without the on-SoC WCN3990 stack. And
  device-mode ECM already gives host-PC networking over the cable.
- **Difficulty:** moderate. DWC3 is well documented and we already drive it in
  device mode.

## Stack 2 — Wi-Fi (the prize; the hardest)

- **Chip/transport:** WCN3990 over **SNoC** (not PCIe), ath10k-class.
- **It's SoftMAC.** ath10k is a **mac80211/SoftMAC** driver: the 802.11 MAC logic
  (MLME, scanning, association, fragmentation) lives in the *host* `mac80211`
  stack, with only some tasks offloaded to firmware over WMI/HTT. XNU has no
  `mac80211`. So a native port must re-implement the SoftMAC MAC layer in-driver
  (or inside the IO80211 glue), not just talk to the chip. This is the single
  biggest reason Wi-Fi is "months, not weeks".
  ([ath10k = mac80211 SoftMAC](https://deviwiki.com/wiki/Ath10k),
  [SoftMAC vs FullMAC](https://deepwiki.com/mars-research/lvd-linux/7.4-wireless-networking:-mac80211-ath10k-iwlwifi-and-realtek))
- **Bring-up chain (ath10k_snoc model):** remoteproc (modem/ADSP) up → **QMI**
  `wlfw` firmware handshake → load firmware + `board-2.bin` (`oneplus_sdm845`) →
  **WMI/HTC** control over **copy engines (CE)** → datapath (Rx/Tx) → associate →
  **WPA2/RSN** → hand frames to the OS network stack.
- **XNU glue:** an **IO80211Controller/Interface** subclass feeding **Skywalk**,
  plus WPA2 done in-driver (no wpa_supplicant).
- **Reference — Snapintosh `drivers/snap-qcc2072/`:** a *full Qualcomm Wi-Fi
  driver on XNU* with exactly this shape — `qcc2072-qmi`, `-wlfw`, `-wmi`, `-htc`,
  `-ce`, `-qrtr`, `-datapath`, `SnapintoshQCC2072Interface.cpp` (IO80211), and
  `native-wpa2`/`native-rsn` crypto. Caveat: QCC2072 is a Wi-Fi 7 part on **MHI
  over PCIe**, so its **transport** differs from our SNoC; the upper layers
  (QMI/WLFW/WMI/HTC/CE/IO80211/WPA2) are the transferable method. The protocol
  reference for the SNoC/ath10k side is Linux `ath10k_snoc`.
- **Big dependency:** the modem/ADSP **remoteproc + QMI** must come up first.
  That is a prerequisite project in itself (and the `0074-sweet-usb-vbus` and
  rpmh plumbing suggest some platform groundwork exists).
- **Difficulty:** high — months. The biggest single connectivity effort.

## Stack 3 — Bluetooth (self-contained transport, hard stack above)

- **Chip/transport:** WCN3990 BT over **UART**, QCA protocol (`hci_qca`), with
  power sequencing and per-device NVM (`crnv21.bin`) + firmware (`crbtfw`).
- **XNU glue:** the hard part is above HCI — Apple's IOBluetooth is large and
  closed. A realistic first step is a **UART HCI transport** + raw HCI
  (inquiry/connect) for a proof of life, not the full Apple stack.
- **Reference:** no XNU BT reference in the projects studied (Snapintosh has no
  Bluetooth). Linux `hci_qca`/`btqca` is the transport reference.
- **Difficulty:** transport is moderate and self-contained; a usable stack above
  it is high.

---

## Suggested priority

1. **USB host mode → dongle → `utun`** — builds on what works (device-mode DWC3 +
   CDC-ECM), moderate effort, and is the **fastest path to real internet**: a USB
   Wi-Fi/Ethernet dongle driven in userland, packets to a `utun` interface, no
   modem stack and no IO80211. Best return for the risk.
2. **Bluetooth HCI proof-of-life** — a UART HCI transport (`hci_qca` model:
   power-sequence the WCN3990, download `crbtfw`/`crnv`, then standard H4 HCI) is
   self-contained and cheap for a "radio answers" milestone. A usable Apple-side
   stack above it is a separate, large effort.
3. **Native Wi-Fi (WCN3990)** — the real prize, explicitly **two stages**:
   (a) stand up modem/ADSP **remoteproc + rmtfs + QMI** (prerequisite milestone —
   nothing Wi-Fi works without it); then (b) the ath10k-class driver
   (QMI/WLFW/WMI/HTC/CE + the SoftMAC MAC layer) feeding either a real
   IO80211Controller *or*, pragmatically, `utun`. Snapintosh `qcc2072` is the
   method reference (its transport is PCIe/MHI, ours is SNoC); Linux `ath10k_snoc`
   is the protocol reference. Months.

Rationale for putting the dongle path first: Snapintosh shows even a native
IO80211 Qualcomm driver can't yet join from the OS Wi-Fi menu, and on-SoC Wi-Fi
drags in the entire modem/remoteproc subsystem. A dongle sidesteps both and
reuses the networking shape we already have.

## Open questions / unknowns

- Is the **ADSP/modem remoteproc + QMI** reachable from our XNU today? (Wi-Fi is
  blocked on it.) What rpmh/SMEM/QRTR plumbing already exists in the port?
- How much of Apple's **IO80211Family / Skywalk / IOUSBHostFamily** survives in
  our cut-down XNU, and what must be stood up?
- Does the bootloader leave the **USB PMIC/VBUS** and Type-C in a state we can
  take to host mode without extra PMIC programming?
- Firmware provenance: the WCN3990 Wi-Fi/BT firmware and `board-2.bin` must be
  obtained from the device/linux-firmware and kept **out of git** (see AGENTS.md).

## Links

**Wi-Fi / WCN3990 / ath10k:**
- WCN3990 OnePlus 6/6T board file: https://lists.infradead.org/pipermail/ath10k/2023-December/015066.html
- OnePlus ath10k calibration variant (DTS): https://lkml.org/lkml/2025/11/10/1254
- WCN3990 SDM845 WLAN device-tree node (2018 enablement): https://patchwork.ozlabs.org/cover/993061/
- ath10k is mac80211 / **SoftMAC**: https://deviwiki.com/wiki/Ath10k
- SoftMAC vs FullMAC (mac80211 does the MAC in software): https://deepwiki.com/mars-research/lvd-linux/7.4-wireless-networking:-mac80211-ath10k-iwlwifi-and-realtek

**Modem / remoteproc / QMI (the Wi-Fi prerequisite):**
- Modem-disabled → `wlan0` never appears (QMI needs remoteproc): https://github.com/ToniMcQueen/oneplus6t-install-linux-Arch-on-arm-845/issues/1
- SDM845 ADSP/CDSP remoteproc support: https://lore.kernel.org/lkml/20180828071458.26858-1-bjorn.andersson@linaro.org/
- Qualcomm remoteproc subsystem overview: https://docs.qualcomm.com/doc/80-70020-3/topic/remoteproc-overview.html

**Bluetooth / WCN3990:**
- hci_qca / WCN39xx power sequencing + `crnv21.bin`: https://bugs.kali.org/view.php?id=9780
- btqca WCN3990 firmware download (`crbtfw`/`crnv`): https://lkml.org/lkml/2018/8/3/419
- Enable Bluetooth for WCN3990 (LWN overview): https://lwn.net/Articles/761109/

**XNU / Apple-side glue:**
- Apple IO80211FamilyV2 architecture (Black Hat 2020): https://i.blackhat.com/USA-20/Thursday/us-20-Wang-Dive-into-Apple-IO80211FamilyV2.pdf
- IO80211 + Skywalk headers absent (acidanthera): https://github.com/acidanthera/MacKernelSDK/pull/13
- Snapintosh — native XNU Qualcomm Wi-Fi (QCC2072, IO80211): https://github.com/Snapintosh/Snapintosh
- Kext-free Wi-Fi via `utun` (RTL8852B dongle on macOS): https://github.com/Long0823-1/rtw89-macos-tun/releases
- RTL8188EU native IO80211 Airport kext (dongle precedent): https://github.com/zexry619/RTL8188EAirport

**USB:**
- SDM845 USB PHY / dwc3 bring-up (2018): https://lkml.iu.edu/hypermail/linux/kernel/1805.0/01618.html
- IOUSBHost (Apple host-mode user-space USB): https://developer.apple.com/documentation/iousbhost
