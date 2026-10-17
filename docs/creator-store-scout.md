# Creator Store scout (2026-10-17)

Searched the Creator Store through Studio's MCP (`search_asset`, free models): 14 weapon, 14 character and 28
environment queries, about 450 results. Contact sheets: `data/scout/sheet_*.png`; curated picks: `data/scout/picks.png`;
raw results: `data/scout/search.json`; per-asset inspection: `data/scout/inspect.json`.

44 shortlisted assets were inserted into an isolated `ServerStorage/ScoutTmp` folder in Edit mode (nothing ran), checked
for scripts, parts, meshes and size, lined up next to our beaver and goose rigs under the game's lighting, then deleted.
Nothing from the store is in the project yet.

## Safety finding: half the "emoji" listings carry hidden scripts

Static props that ship scripts named `PoseTexture`, `TextureConfiguration`, `Material` + `LocalScript`, `LightConfig` /
`EasyConfiguration` / `Type` (touches MarketplaceService), `CoreSkyboxSystem`, `PoseLink`, `Protocol`, `Package` or
`EffectBuilder`. The ones read (as text, never run) are long "fully commented texture streaming" files: a known template
for burying a backdoor in a free model. A tree or fence never needs code. Rules for this project:

- Prefer script-free assets (marked **clean** below).
- An asset marked **strip** is only usable after deleting every `LuaSourceContainer` before it ever enters a Play session,
  and only its geometry is kept (re-saved as our own model).
- Never insert these into the live place unreviewed; never enable "Allow HTTP" or third-party teleports for them.

## Recommendations

### Weapons (held-gun visuals; our gun stats stay the decoded gz_gunfeel values)

| Pick | Asset | Verdict | Notes |
| --- | --- | --- | --- |
| TT-33 / pistols | [15284785812](https://create.roblox.com/store/asset/15284785812) Blocky Gun! | **clean**, 34 parts | Toy pistol with an orange tip; exactly the brief's toy language |
| AK family | [4762550889](https://create.roblox.com/store/asset/4762550889) Improved Low-Poly AK47 | **clean**, 20 parts | Blocky red/grey AK; scale to the hand socket |
| Shotguns | [102599014388952](https://create.roblox.com/store/asset/102599014388952) Low Poly Shotgun | **clean**, 1 union | Wood + grey, reads at top-down distance |
| SMGs | [6169371009](https://create.roblox.com/store/asset/6169371009) MAC10 | **clean**, 73 parts | Comes in at a huge scale; normalise |
| Grenade | [13759819215](https://create.roblox.com/store/asset/13759819215) mega low poly grenade | **clean**, 1 mesh | For the throwables pass |
| Sniper | [10176497750](https://create.roblox.com/store/asset/10176497750) Low poly sniper rifle | clean except a `READ ME` script (115 chars) | Delete the note script |
| Big packs | [127406876486021](https://create.roblox.com/store/asset/127406876486021), [99363602592974](https://create.roblox.com/store/asset/99363602592974) gun packs | **strip** (Material / PoseTexture scripts) | 326 and 802 meshes covering most of our 44 guns; good geometry, unsafe scripts |
| Stick / bat | [106991110510862](https://create.roblox.com/store/asset/106991110510862) Pixel Baseball Bat | **strip** | Blocky plank look fits "Wooden Stick" |

### Characters (style references; see the rig note)

| Role | Asset | Verdict | Notes |
| --- | --- | --- | --- |
| Beaver | [610672667](https://create.roblox.com/store/asset/610672667) beaver! | **clean**, 41 parts | Blocky beaver; tiny (2.5 studs), useful silhouette reference |
| Scav goose | [5214541892](https://create.roblox.com/store/asset/5214541892) Goose | **clean**, 13 parts | Blocky white goose, very toy |
| Canada goose | [481151177](https://create.roblox.com/store/asset/481151177) Canada Goose | **clean**, 87 parts | Best "Canada goose" read of all results |
| Moose (brute head) | [130531510](https://create.roblox.com/store/asset/130531510) Moose | **clean**, 14 parts | Blocky moose; antler shape for the heavy goose's moose head |
| Bear boss | [5409485582](https://create.roblox.com/store/asset/5409485582) cartoon bear | **clean**, 14 parts | Blocky brown bear |
| Wolverine | [440929613](https://create.roblox.com/store/asset/440929613) low poly wolf | **clean**, 1 mesh | Huge import scale |
| Merchant | [87952762503596](https://create.roblox.com/store/asset/87952762503596) raccoon | **clean**, 1 mesh | Cartoon raccoon for the raccoon merchant |
| Extras | [90921659942122](https://create.roblox.com/store/asset/90921659942122) Blocky animals | **clean**, 263 parts | Deer / fox / etc. pack |

**Rig note:** store animals are static models. Our characters animate bone-mounted boxes from the decoded source clips
(`shared/Skel.luau`), so a store model can only replace our rig after being split into parts per bone (or rebuilt in
Blender on the skeleton). Treat these as the art target for the beaver / goose / moose / bear restyle, not drop-ins.

### Environment

| Use | Asset | Verdict | Notes |
| --- | --- | --- | --- |
| Pines (473 trees) | [5616880673](https://create.roblox.com/store/asset/5616880673) Low poly pine tree | **clean**, 2 meshes | Bright faceted toy pine; one mesh instanced = cheaper than our 4-part pines |
| Bushes (fow foliage) | [7191673673](https://create.roblox.com/store/asset/7191673673) Low Poly Bush | **clean**, 1 mesh | |
| Rocks | [121683951170092](https://create.roblox.com/store/asset/121683951170092) Low Poly Rock | **clean**, 1 mesh | Could dress the rock bands |
| Ranger cabin / houses | [4746497269](https://create.roblox.com/store/asset/4746497269) Log Cabin | **clean**, 266 parts | Green roof, very Canadian; heavy part count |
| Container yard | [8473839456](https://create.roblox.com/store/asset/8473839456) shipping container | **clean**, 2 meshes | |
| Oil barrels | [5228772587](https://create.roblox.com/store/asset/5228772587) Oil barrel | **clean**, 7 parts | Red with bands, matches our explosive barrel |
| Pickup trucks / car wreck | [13106047107](https://create.roblox.com/store/asset/13106047107) Low-poly Pickup Truck | **clean** but the body unions did not render in the lineup (wheels only) | Re-check before use |
| Cars | [113700576399250](https://create.roblox.com/store/asset/113700576399250) Low Poly Cars | **clean**, folder of 7 meshes | |
| Cliff edges | [135349084762380](https://create.roblox.com/store/asset/135349084762380) grass-top cliff | **strip** | Great match for the ledge borders |
| Hunter stand | [72105624698726](https://create.roblox.com/store/asset/72105624698726) forest tower | **strip** | Fits the hunter stand POI |
| Fences | [134223238872685](https://create.roblox.com/store/asset/134223238872685) chunky fence | **strip** | |
| Crates | [138288398183601](https://create.roblox.com/store/asset/138288398183601) crate stack | **strip** (MarketplaceService touch) | |
| Campfire (hazard) | [127425714970796](https://create.roblox.com/store/asset/127425714970796) campfire | **strip** | |
| Camp tents | [105266050548778](https://create.roblox.com/store/asset/105266050548778) camp tent | **strip** | |
| Bridge | [82010036400929](https://create.roblox.com/store/asset/82010036400929) wooden bridge | **strip** | |
| Bunker hatch | [119562756216506](https://create.roblox.com/store/asset/119562756216506) round hatch | **strip** (4 scripts incl. `CoreSkyboxSystem`) | |
| Flags | [18586420099](https://create.roblox.com/store/asset/18586420099) Canada Flag | only an `Animate` script (241 chars) | Read before use |
| Sandbags | [87392862973649](https://create.roblox.com/store/asset/87392862973649) | **strip** (4 suspicious scripts) | |
| Water tower | [91195860309114](https://create.roblox.com/store/asset/91195860309114) | **strip** | |
| Radio / signal tower | [8788183000](https://create.roblox.com/store/asset/8788183000) radio tower | **clean**, 1 mesh | The quest's SignalTower |

### Rejected

- [10647998996](https://create.roblox.com/store/asset/10647998996) Goose: six scripts (Animate, Respawn, Wonder, ...), an NPC kit, not a model.
- [106089670751518](https://create.roblox.com/store/asset/106089670751518) "99 Nights" bear: another game's IP plus backdoor-pattern scripts.
- [12325172605](https://create.roblox.com/store/asset/12325172605) Shrek's Outhouse and [1213327466](https://create.roblox.com/store/asset/1213327466) Lumber Tycoon 2 maple: third-party IP.
- Untitled Goose Game look-alikes ([13605683583](https://create.roblox.com/store/asset/13605683583) and similar): IP likeness.
- [15925666984](https://create.roblox.com/store/asset/15925666984) ranger beaver: a single 26-stud part, no geometry to use.

## Rights and next steps

A free listing does not establish rights; uploads can be re-licensed, taken down or swapped. For anything we keep:
re-save the cleaned geometry as our own asset, record the source id and creator here, and re-check before publishing.
Suggested order: pines + bushes + rocks (biggest visual win, fewer parts), held guns on the hand socket, then the
character restyle using the blocky beaver / goose / moose / bear as references.
