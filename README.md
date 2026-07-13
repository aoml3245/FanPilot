# FanPilot

FanPilot is a macOS menu bar fan controller built in Swift. It reads Apple SMC fan and temperature data, supports multiple rules per fan, and writes fan targets through a privileged helper when direct SMC writes are not permitted.

## Features

- Menu bar status with current driving temperature and max fan RPM.
- Per-fan rule editing.
- Ramp rules based on sensor temperature.
- Fixed RPM rules.
- CPU/GPU max and average computed sensors.
- Launch-at-login setting.
- Background operation with a menu bar dropdown.
- Privileged helper fallback for fan writes.
- Heartbeat watchdog and fan reset on shutdown.
- File logging for app and helper errors.

## Build

```sh
cd FanPilot
swift build
swift run FanPilot --self-test
```

## Package

```sh
cd FanPilot
bash scripts/package_app.sh
```

The packaged app is written to `outputs/FanPilot.app`.

## Install Helper

Fan writes require the privileged helper on machines where direct SMC writes are denied:

```sh
cd FanPilot
bash scripts/install_helper.sh
```

The helper can be removed with:

```sh
cd FanPilot
bash scripts/uninstall_helper.sh
```

## Logs

- App log: `~/Library/Application Support/FanPilot/fanpilot.log`
- Previous app log: `~/Library/Application Support/FanPilot/fanpilot.previous.log`
- Helper log: `/Library/Logs/FanPilotHelper.log`

## Safety

FanPilot resets fan control on normal shutdown. The helper also has a heartbeat watchdog that resets fan control if the app stops sending heartbeats while manual control is active.
