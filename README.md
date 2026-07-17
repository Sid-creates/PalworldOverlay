# PalworldOverlay

A desktop companion overlay for **Palworld 1.0** that tracks relics and Lifmunk effigies on the real world map. A UE4SS bridge auto-marks pickups as you collect them — no more fighting the in-game **50-pin** limit.

Progress is stored locally on your machine.

## Features

- Full Palpagos + World Tree map overlay with **405** seeded relic locations
- Filter by remaining, collected, or all; toggle categories (capture, swim, jump, climb, etc.)
- Live player cursors when the game bridge is connected (multiplayer: all players on the map + pick who to track)
- Auto check-off on pickup via UE4SS memory scanning
- Manual toggle (right-click / double-click a marker)
- Electron overlay: **F8** hide/show · `Ctrl+Shift+A` always-on-top · system tray

## Requirements

- **Windows** (tested on Palworld PC / Steam)
- **Palworld 1.0**
- Internet (first run downloads Node.js if needed, map textures, and optionally UE4SS)

`install.bat` will install **Node.js 20+** automatically when missing (via `winget`, or the official MSI).

## Installation

### Easy install (recommended)

From the repo root, double-click **`install.bat`** or run:

```powershell
.\install.ps1
```

If Node install fails with a permissions error, right-click **`install.bat` → Run as administrator** once.

The installer will:

1. Install Node.js LTS if missing / too old
2. Download map textures into `companion/public/maps/`
3. Run `npm install` for the companion app
4. Auto-detect your Palworld `Win64` folder (Steam libraries + common paths)
5. Install UE4SS if missing (optional prompt)
6. Copy and enable the `PalworldAssistBridge` mod in `Mods\mods.txt`
7. Create `%LOCALAPPDATA%\PalworldAssist\`
8. Create **`start-overlay.bat`** to launch the overlay

Options:

```powershell
.\install.ps1 -PalworldPath "D:\SteamLibrary\steamapps\common\Palworld"
.\install.ps1 -Launch            # install, then start the overlay
.\install.ps1 -SkipUe4ss         # skip UE4SS download (you already have it)
.\install.ps1 -SkipNodeInstall   # do not auto-install Node
```

After install, run **`start-overlay.bat`**, then fully restart Palworld.

### Manual install

#### 1. Clone the repo

```powershell
git clone https://github.com/Sid-creates/PalworldOverlay.git
cd PalworldOverlay
```

#### 2. Map textures

Place the two map images in `companion/public/maps/`:

```text
companion/public/maps/
├── palworld-map.webp      # Palpagos main map
└── palworld-treemap.webp  # World Tree map
```

These are not bundled in the repo (large game assets). Community ports used by projects like [palworld-save-pal](https://github.com/oMaN-Rod/palworld-save-pal) and palworld-server-manager work with this coordinate system. See `data/ATTRIBUTION.txt`.

#### 3. Companion app

```powershell
cd companion
npm install
npm run dev:app
```

| Command | What it does |
| --- | --- |
| `npm run dev` | Vite UI only (browser, no overlay) |
| `npm run dev:app` | Vite + Electron overlay (recommended) |
| `npm run build` | Production web build |
| `npm start` | Run Electron against a built `dist/` |

On first launch the app creates:

```text
%LOCALAPPDATA%\PalworldAssist\
├── progress.json   # your collected markers
└── live.json       # written by the UE4SS bridge
```

**Start the companion before launching Palworld** so that folder exists before the mod runs.

#### 4. UE4SS + bridge mod

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) into your Palworld binaries folder:

   ```text
   <Palworld>\Pal\Binaries\Win64\
   ├── UE4SS.dll
   ├── dwmapi.dll
   └── Mods\
   ```

2. Copy this repo's bridge mod into `Mods`:

   ```text
   <Palworld>\Pal\Binaries\Win64\Mods\PalworldAssistBridge\
   ├── mod.json
   └── Scripts\
       └── main.lua
   ```

   From the repo root:

   ```powershell
   Copy-Item -Recurse bridge\PalworldAssistBridge "<Palworld>\Pal\Binaries\Win64\Mods\"
   ```

3. Enable the mod in `Mods\mods.txt`:

   ```text
   PalworldAssistBridge : 1
   ```

4. **Fully close Palworld** (and any injectors/trainers), then relaunch with the companion already running.

When the bridge is working, `%LOCALAPPDATA%\PalworldAssist\live.json` updates every few hundred ms with player position and nearby relic state.

## How it works

```text
Palworld (UE4SS) → %LOCALAPPDATA%\PalworldAssist\live.json → Electron companion → map + progress.json
```

1. The companion loads seeded coordinates from `data/relics.json`.
2. The UE4SS Lua mod scans loaded relic actors and player position.
3. Pickups and `bPickedInClient`-style flags auto-mark progress; you can also toggle markers manually.

## Seed data

`data/relics.json` (served from `companion/public/data/`) includes **405** relics for Palworld 1.0:

- 153 Lifmunk Effigies (`capture_power`)
- Pal effigies (swim, jump, climb, glider, stamina, hunger, resist, food decay, …)
- A few specials (EXP / sphere homing / rainbow)

Coordinates derived from [palworld-save-pal](https://github.com/oMaN-Rod/palworld-save-pal) (MIT). MapGenie inspired the UX; we do **not** scrape MapGenie.

## Hotkeys & usage

| Key | Action |
| --- | --- |
| **F8** | Hide / show overlay |
| **Ctrl+Shift+A** | Toggle always-on-top |
| **Right-click / double-click** marker | Toggle collected |
| Tray icon | Show window or quit |

Close the window to hide to tray; quit from the tray menu.

## Multiplayer

The UE4SS bridge enumerates every `PalPlayerCharacter` on the client and writes them to `live.json` as `players[]` (name + position). The overlay draws **all** of them and lets you pick who to track (area auto-follow + in-game relic count). Choice is remembered locally.

If names show as `Player 1` / `Player 2`, the game didn't expose a nick on that build — positions still work. After updating the bridge mod, fully restart Palworld so UE4SS reloads it.

## Known limits

- Save files store an effigy **count**, not per-location state — live tracking needs the bridge.
- Only **loaded/nearby** world objects are visible to the game; distant markers stay on the static seed until you get close.
- Actor class names can change after Palworld patches; the Lua scanner may need updates.
- Dedicated-server hosts without a local client pawn may not see remote players until they are replicated to your client.

## Repo layout

```text
PalworldOverlay/
├── install.ps1 / install.bat      # one-shot setup
├── start-overlay.bat              # launch companion (created by installer)
├── bridge/PalworldAssistBridge/   # UE4SS Lua mod
├── companion/                     # Electron + React map overlay
│   ├── electron/                  # main process, live.json watcher
│   ├── public/data/               # relic seed served to the UI
│   └── public/maps/               # map textures (you provide)
├── data/                          # source seed + attribution
└── README.md
```

## License

Seed coordinates: MIT (via palworld-save-pal). Project code: use and modify freely; no warranty.
