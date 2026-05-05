# Smartcar Integration (stefhome fork)

## Quick Reference

- **Deployed to**: `/mnt/homeassistant/custom_components/smartcar/`
- **GitHub fork**: https://github.com/nstefanelli/ha-smartcar (origin)
- **Upstream**: https://github.com/wbyoung/smartcar (`upstream` remote)
- **Devices**: 2024 BMW iX xDrive50, 2025 BMW i7 xDrive60, 2026 BMW X7 xDrive40i (3 vehicles, single config entry)
- **Smartcar app**: client_id `00000000-0000-0000-0000-000000000000` (BMW Mobile SDK pair). app_creds id `smartcar_REDACTED_app_creds_id`. config_entry_id `REDACTED_entry_id`.
- **Auth**: OAuth2 via Smartcar's mobile SDK pairing — tokens minted out-of-band (BMW US blocks web flow with hCaptcha) and injected; HA's stock OAuth2 refresh handles rotation.
- **IoT class**: `cloud_polling` (default 6h, 30min while charging). Webhooks supported (not yet enabled).
- **API tier**: Free (500 calls/month/vehicle). 6h polling × 3 cars = ~360/month total.

## Fork tracking

- **Initial commit on fork**: `f501522` (2026-05-04)
- **Released**: `v0.4.7-bmw.1`
- **Forked from upstream**: `wbyoung/smartcar@main` as of 2026-05-04 (upstream version `0.4.6`)
- **Sync command**: `git fetch upstream && git merge upstream/main` (resolve conflicts on `main`)
- **PR-back candidates**: manual-token reauth path (broadly useful)
- **Local-only changes**: none yet (all changes in this fork are upstream-eligible)

## File map

| File | Purpose |
|---|---|
| `custom_components/smartcar/config_flow.py` | OAuth2 + reauth flow. **Fork adds `async_step_manual_token`** + menu in `async_step_reauth_confirm`. |
| `custom_components/smartcar/auth_impl.py` | `AsyncConfigEntryAuth` (refresh-aware) + `AccessTokenAuthImpl` (bare token, used during config flow). |
| `custom_components/smartcar/application_credentials.py` | Returns Smartcar's authorize/token URLs for HA's `application_credentials` system. |
| `custom_components/smartcar/__init__.py` | Entry setup. Reads `entry.data.vehicles`, creates one `SmartcarVehicleCoordinator` per vehicle, registers devices, forwards to platforms. |
| `custom_components/smartcar/coordinator.py` | Per-vehicle `DataUpdateCoordinator` with adaptive polling (30min when charging, 6h otherwise). |
| `custom_components/smartcar/const.py` | `Scope` enum (read_*, control_*), `REQUIRED_SCOPES` (read_vehicle_info + read_vin), `DEFAULT_SCOPES`, `CONFIGURABLE_SCOPES`, `OAUTH2_AUTHORIZE/TOKEN`. |
| `custom_components/smartcar/util.py` | `unique_id_from_entry_data()` = sorted vehicle UUIDs (so reauth identifies same set). |
| `custom_components/smartcar/{sensor,switch,lock,device_tracker,binary_sensor,number}.py` | Platforms. **No `climate.py` yet** — Phase 2 adds it. |

## Common tasks

### Re-pair after BMW invalidates Smartcar grant

When HA shows the "Smartcar needs reauth" notification:

1. **Mint new tokens via mobile SDK** on macstudio:
   ```bash
   ssh nstefanelli@172.27.10.56
   cd ~/sterling/tools/bmw-pair && ./.build/debug/BMWPair
   ```
   Click "Connect BMW" → sign in → authorize all 3 vehicles → auth code copied to clipboard.

2. **Exchange auth code for tokens**:
   ```bash
   cd ~/sterling/tools/bmw-pair
   CLIENT_SECRET=<from 1Password> ./exchange.sh <paste_code>
   # → tokens.json (access_token + refresh_token)
   ```

3. **Paste into HA UI**: click reauth notification → choose **Manual token entry** → paste `access_token` and `refresh_token` from `tokens.json` → submit.

4. Done. HA reloads the config entry. No HA restart, no `inject.py`, no SSH-to-HA.

### Sync from upstream

```bash
cd /mnt/home-automation/homelab/ha-integrations/ha-smartcar
git fetch upstream
git merge upstream/main           # or rebase if you prefer linear history
# Resolve conflicts; bump manifest.json version (e.g. 0.4.8-stefhome.1)
# Update CLAUDE.md "Fork tracking" with new upstream SHA/version
git push origin main
gh release create v<new-version> --target main --title "..." --notes "..."
```

After release: HACS will surface the update.

### Deploy a fork change to running HA

If managed via HACS custom repo: HACS → Integrations → Smartcar → Update. HA restart required.

If managed via direct cp (current state until HACS swap is done):
```bash
sudo cp -r /mnt/home-automation/homelab/ha-integrations/ha-smartcar/custom_components/smartcar /mnt/homeassistant/custom_components/smartcar
# restart HA via API:
curl -sS -X POST -H "Authorization: Bearer $HA_TOKEN" http://172.27.10.10:8123/api/services/homeassistant/restart
```

### Add a new platform (e.g. climate)

1. Create `custom_components/smartcar/climate.py` with `async_setup_entry` + entity class.
2. Register `"climate"` in `PLATFORMS` list in `const.py`.
3. Wire scopes if a new scope is needed: add to `Scope` enum, `CONFIGURABLE_SCOPES`, optionally `DEFAULT_SCOPES`.
4. Add translation keys in `translations/en.json` under `config.step.scopes.data` for the new scope.
5. Test on `ha-test` (172.27.10.218) before deploying to production.

## Gotchas

- **OAuth web flow is captcha-blocked for new BMW US pairings** since 2025-09. Use the manual_token reauth path (this fork) or `inject.py` (in `docs/plans/data/bmw-smartcar/`) for initial setup.
- **`read_vin` is in `REQUIRED_SCOPES`** — the auth flow MUST request it or the integration silently fails to populate vehicle metadata.
- **Smartcar's `/oauth/token` refresh endpoint does NOT require `redirect_uri`** — verified empirically. HA's stock OAuth2Session refresh works fine with mobile-SDK-minted tokens.
- **Multiple vehicles must come in via a single grant.** Smartcar's pairing UI lets the user select multiple at once. The integration's `unique_id` is the sorted joined vehicle IDs — different vehicle sets create different config entries.
- **Free tier has 500 calls/month per vehicle.** Default polling is fine; do not crank it down.
- **HA must be fully stopped before editing `.storage/`** — necessary if using `inject.py` for initial setup. Not needed for the manual_token reauth flow (handled via UI).

## Related

- BMW pairing infrastructure (mobile SDK shim, exchange script): `~/sterling/tools/bmw-pair/` on macstudio
- Initial setup runbook + `inject.py`: `/mnt/home-automation/homelab/docs/plans/completed/2026-05-04-bmw-smartcar-mobile-sdk.md` and `docs/plans/data/bmw-smartcar/`
- Smartcar mobile SDK source we modeled the bridge on: https://github.com/smartcar/ios-sdk
