# Endpoint discovery: public sources reviewed

| Repo | Commit | Language | Routes used | History? |
|---|---|---|---|---|
| RiiotLabs/Blue-backend-automation | 9946c11 (2022-06-27) | docs | automation API: `lastMeasurement`, `configureWebhook` | no |
| LordMike/MBW.Client.BlueRiiotApi | 44cbd44 (2026-10-09) | C# | most complete mobile-API client (`BlueClient.cs:108-225`) | no |
| MikeJMcGuire/hass-blueriiot | 786fcaf (2023-11-13) | C# | wraps MBW client 0.8.5 | no |
| VanAxl/homebridge-blueconnect | 0e34bcc (2025-06-24) | JS | `blueriiot-api.js:370-394` endpoint list | no |
| ChrisbyChA/ha-pool-management-blueriiot | 06e8335 (2026-05-29) | Python | login, pools, blue, lastMeasurements | no |
| ~12 further HA/ioBroker/Jeedom/Homey clients | various | – | subsets of the above | no |

No public client calls a history route. The `measures` route comes only from app traffic (see `historical-data.md`). Full per-endpoint evidence is in `../API_SPECIFICATION.md`.
