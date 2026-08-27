# Manual Test Plan

Ticket §24.4. These are the tests that cannot be automated, because they need real hardware
on the other end of a real cable — a device that asks for an address, a plug that gets pulled,
a network that must be observed not to break.

## Before you start

- A Mac running **macOS 14.0 or later**. Note which version; the app targets 14.0 but is
  developed on 15, and the `SMAppService` approval flow differs between them
  (`Docs/RISKS.md` R-10).
- A **USB-C or Thunderbolt Ethernet adapter**. Not the built-in port if that is what carries
  your internet connection — the app will refuse it, which is Test D's job to confirm.
- A **test device** with a management port: a BMC, a switch, or anything that requests DHCP.
- Wi-Fi connected, so there is a default route on a *different* interface throughout.

```bash
make build
Scripts/install-dev-app.sh
```

Then complete the helper approval in `Docs/PRIVILEGED_HELPER.md` §2.

Keep this open in another window for the whole session:

```bash
log stream --predicate 'subsystem BEGINSWITH "com.bee.dnsmasqformac"' --level debug
```

Record the result of every step. A step that "seemed fine" is not a pass.

---

## Test A — Direct connection to a device

The main scenario. If this does not work, nothing else matters.

1. Keep Wi-Fi connected. Confirm you have internet: `curl -sS -o /dev/null -w '%{http_code}\n' https://example.com`
2. Connect the USB Ethernet adapter to the test device.
3. Open Dnsmasq for Mac. Select the USB Ethernet interface.
4. Confirm the profile shows `192.168.50.1/24` and a pool of `192.168.50.10–200`.
5. Tick the isolation confirmation.
6. Click **Validate Configuration**. Every check should pass. Link Down is acceptable as a
   *warning* if the device is not powered yet.
7. Click **Start**.

Then verify, and write down what you saw:

| # | Check | How |
|---|---|---|
| A1 | The alias exists | `ifconfig en7` shows `inet 192.168.50.1 netmask 0xffffff00` |
| A2 | **Wi-Fi is untouched** | `netstat -rn -f inet \| grep default` still names the Wi-Fi interface |
| A3 | Internet still works | `curl -sS -o /dev/null -w '%{http_code}\n' https://example.com` returns 200 |
| A4 | The device gets an address | It reports something in `192.168.50.10–200` |
| A5 | The lease appears within 2 seconds | Leases page (Phase 9) |
| A6 | The exchange is logged | Logs page shows DISCOVER, OFFER, REQUEST, ACK (Phase 10) |
| A7 | dnsmasq runs as `nobody` | `ps -o user,pid,comm -p $(pgrep -f 'HelperTools/dnsmasq')` |

> **A7 matters more than it looks.** The generated config sets `user=nobody`, and macOS's
> `nobody` is uid `-2` — an unusual value that is not proven to work here until this is seen
> on a real machine (`Docs/RISKS.md` R-08). If dnsmasq is running as `root`, stop and report it.

8. Click **Stop**.

| # | Check | How |
|---|---|---|
| A8 | The alias is gone | `ifconfig en7` no longer lists `192.168.50.1` |
| A9 | dnsmasq is gone | `pgrep -f 'HelperTools/dnsmasq'` finds nothing |
| A10 | Nothing is left in the runtime dir | `sudo ls /var/db/com.bee.dnsmasqformac/` — no `active-session.json` |
| A11 | Wi-Fi is still fine | Repeat A2 and A3 |

---

## Test B — DNS

1. Add a local A record: `bmc01` → `192.168.50.20`. Save the profile.
2. Start.
3. From the client device, or from this Mac:

```bash
nslookup bmc01.lab.test 192.168.50.1
```

| # | Expected |
|---|---|
| B1 | Returns `192.168.50.20` |
| B2 | `nslookup bmc01 192.168.50.1` also resolves — the short name is written too |
| B3 | `nslookup example.com 192.168.50.1` resolves through the upstream servers |
| B4 | With **Local Records Only**, B3 *fails* — that is the mode working, not a bug |
| B5 | `/etc/hosts` on this Mac is unchanged: `git diff` on a copy, or check its mtime |

4. Stop.

---

## Test C — Port conflict

1. Start another DHCP server first, so UDP 67 is taken. Anything will do:

```bash
sudo python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', 67)); input('holding UDP 67 — press return to release\n')"
```

2. In Dnsmasq for Mac, click **Validate Configuration**.

| # | Expected |
|---|---|
| C1 | Preflight reports a UDP 67 conflict as an **error** |
| C2 | The message names the holding process |
| C3 | **Start** is unavailable |
| C4 | **No alias was added** — `ifconfig en7` is unchanged. Preflight is read-only (§14) |

3. Release the port. Validate again; it should pass.

### C5 — the race

Harder, and worth doing once: validate successfully, then take port 67 *before* clicking
Start. Start must fail with a port conflict **and roll the alias back out** — `ifconfig en7`
must not show `192.168.50.1` afterwards. This is ticket §15.1 step 12.

---

## Test D — Configurations that must be refused

Each of these must be refused **both** in the UI and by the helper. The second half matters:
the UI can be bypassed, the helper cannot.

| # | Change | Expected |
|---|---|---|
| D1 | Range `192.168.51.10–200` (outside the subnet) | Error naming the subnet |
| D2 | Range that includes `192.168.50.1` | Error saying the pool contains this Mac |
| D3 | Local domain `lab.local` | Error explaining `.local` belongs to Bonjour |
| D4 | Custom DNS with no servers | Error asking for at least one |
| D5 | DHCP off *and* DNS off | Error saying there is nothing to start |
| D6 | Select the **Wi-Fi** interface | Cannot be selected; reason shown |
| D7 | Select the interface carrying the **default route** | Cannot be selected; reason shown |
| D8 | Untick the isolation confirmation | **Start** unavailable |

---

## Test E — App crash recovery

1. Start a session. Confirm the device has an address.
2. Force-quit the app: `pkill -9 Dnsmasq for Mac`

| # | Expected |
|---|---|
| E1 | dnsmasq **keeps running** — `pgrep -f 'HelperTools/dnsmasq'` still finds it |
| E2 | The device keeps its address; the network is undisturbed |

3. Reopen Dnsmasq for Mac.

| # | Expected |
|---|---|
| E3 | It shows **Running**, not Stopped |
| E4 | The interface and profile shown match what is running |
| E5 | **Stop** is available |
| E6 | Stop works, and A8–A10 hold afterwards |

> E3 is the point of the journal. An app that reopened to Stopped while dnsmasq was still
> serving would leave the user with no way to stop it from the UI.

---

## Test F — dnsmasq exits unexpectedly

1. Start a session.
2. Kill dnsmasq directly: `sudo pkill -f 'HelperTools/dnsmasq'`

| # | Expected |
|---|---|
| F1 | The app notices within a few seconds and shows an error |
| F2 | The **alias is removed automatically** — `ifconfig en7` no longer lists it |
| F3 | dnsmasq is **not** restarted. Ticket §17.4 forbids it; a crash loop against a network the user cannot see would be worse than a stopped service |
| F4 | The journal is cleared: `sudo ls /var/db/com.bee.dnsmasqformac/` |
| F5 | The error includes the tail of the log |

---

## Test G — Adapter unplugged mid-session

1. Start a session.
2. Physically unplug the USB Ethernet adapter.

| # | Expected |
|---|---|
| G1 | The app reports the interface is gone |
| G2 | The session ends or moves to a failure state — it does not sit claiming Running |
| G3 | The journal is eventually cleared |
| G4 | Replugging does **not** start anything automatically (ticket §0.1) |
| G5 | A fresh Start afterwards works normally |

---

## Test H — Recovery from an unclean helper shutdown

Confirms the journal actually drives cleanup, which is the one path Tests E–G do not
isolate.

1. Start a session.
2. Kill the helper without stopping: `sudo pkill -f com.bee.dnsmasqformac.helper`
3. Confirm the alias is still on the interface, and dnsmasq may still be running.
4. Open the app, or click Start again.

| # | Expected |
|---|---|
| H1 | The helper restarts on demand and reconciles the journal |
| H2 | If dnsmasq is still alive and verified, the session is re-adopted |
| H3 | If it is gone, the orphaned alias is removed before anything new starts |
| H4 | The user is told cleanup happened — silently fixing it teaches nothing |

---

## Result

Record for each test: **pass**, **fail**, or **not run**, with the macOS version and adapter
model. A test that was not run is reported as not run — ticket §30 §7 is explicit that
untested items must not be presented as passing.
