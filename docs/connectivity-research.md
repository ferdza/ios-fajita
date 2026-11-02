# Connectivity research — Wi-Fi, Bluetooth, USB

Research notes (no implementation yet) for bringing up the OnePlus 6T's
connectivity under this XNU + iOS-userland port. Goal: understand the hardware,
the reference drivers, the realistic path on XNU, and a sensible priority order.

State as of **2026-11-02**. Observations and assumptions are kept distinct;
hardware facts carry a source.

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

1. **USB host mode** — builds on what works, moderate effort, and opens a
   dongle-based connectivity path. Good return for the risk.
2. **Wi-Fi (WCN3990)** — the real goal, but gated on **remoteproc + QMI** first;
   treat that prerequisite as its own milestone. Use Snapintosh qcc2072 as the
   method reference and ath10k_snoc as the protocol reference.
3. **Bluetooth** — a UART HCI transport for a proof of life is cheap; a full
   stack is a later, large effort.

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

- WCN3990 OnePlus 6/6T board file: https://lists.infradead.org/pipermail/ath10k/2023-December/015066.html
- OnePlus ath10k calibration variant (DTS): https://lkml.org/lkml/2025/11/10/1254
- hci_qca / WCN39xx power sequencing + `crnv21.bin`: https://bugs.kali.org/view.php?id=9780
- SDM845 USB PHY / dwc3 bring-up (2018): https://lkml.iu.edu/hypermail/linux/kernel/1805.0/01618.html
