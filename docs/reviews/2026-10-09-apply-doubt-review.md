# Doubt review: Apply design (cycle 1)

_2026-10-09. Skill: doubt-driven-development._

**Claim under test:** Apply never loses a photo.
- A card file is deleted only after its keepers are verified on the SSD.
- Archive files are removed only when they are FujiCull's own verified copies of frames rejected later.
- Any interruption is safe and resumable.

**Method:**
- A fresh-context reviewer received only the contract and the artifact. The contract was REQUIREMENTS §4.1 R1, R6, §4.2, R21, §4.6 and the safety NFR. The artifact was DESIGN D6, D7, §5.3, §5.7, the ADR-003 decision and the measured hardware facts. The reviewer was told to find faults, not to validate.
- A cross-model second opinion was offered; the user chose to skip it for cycle 1.

**Result:** 18 findings. 15 valid, 1 accepted trade-off, 2 partly noise. The noise came from context left out of the extract. The design was revised as DESIGN §5.3 and §5.7 rules SR1–SR17.

| # | Finding (reviewer severity) | Classification | Resolution |
|---|---|---|---|
| 1 | Frame identity undefined: a reformatted card or one that restarts numbering could inherit old decisions and ledger (Critical) | **Valid.** Scenario B (counter wrap) is noise, because FrameID already includes the folder (§5.1, not in the extract). | SR2 frame identity (FrameID + exact file sizes + capture time). The ledger stores the source identity. |
| 2 | Decisions can change during a running Apply (Critical) | **Valid** | SR5 freeze; undo history cleared after deletes; card-delete recheck of the decision (SR16) |
| 3 | Concurrent Apply runs collide on partials and the ledger (Critical/High) | **Valid** in part. "Two windows" is mostly noise for a single-window app, but the same card opened as a volume and as a folder is real. | SR1 one key per card volume, SR6 locks, unique `O_EXCL` partials |
| 4 | Archive root stored as a path could write to the internal disk (High) | **Valid** | SR7 resolve by volume UUID, never create above the trip folder, UUID check before each file |
| 5 | The 50% restore rule discards the ledger after a normal Apply (High) | **Valid** | SR3 counts only frames expected still on the card; versioned session IDs |
| 6 | Ledger per frame, not per role (High) | **Valid.** The design was ambiguous: the executor was per role, the planner per frame. | SR9 everything per (frame, role) |
| 7 | D6 unchanged-check used mtime, which wasn't recorded and is time-zone fragile (High) | **Valid** | SR15 size + SHA-256 re-hash, recorded per destination |
| 8 | A folder source can overlap the archive; non-card sources were permanently deleted (High) | **Valid** | SR8 refuse overlap; Trash for internal-disk sources |
| 9 | MOVs and unpaired files are never archived or reported (High) | **Valid** | SR13 left-on-card list and warning. Q12 was answered on the same day: videos are copied to `<Trip>/Videos/` (R27). Unpaired frames are planned with only the roles their files allow (SR9). |
| 10 | Name comparisons not case or Unicode aware on exFAT (Medium-High) | **Valid** | SR10 |
| 11 | Names allocated within one plan not reserved against each other (Medium) | **Valid** | SR11 |
| 12 | Decision saves and ledger writes race on one file; `fsync` is not `F_FULLFSYNC` (Medium-High) | **Valid** | SR4 separate journal, one writer actor, `F_FULLFSYNC` |
| 13 | Gate trusts the ledger without checking the archive (Medium) | **Valid** | SR12 stat every verified file; replan missing ones; stop if the folder is gone |
| 14 | Source hashed from a single card read (Medium) | **Trade-off** | SR17. Accepted and documented: CRC-protected buses, and a double-read would cost ~10 min per trip. Could become an optional preference later. |
| 15 | Per-file skip splits a pair (Medium) | **Valid** | SR15, SR16 all-or-nothing per frame |
| 16 | No fallback when the ledger is lost (Medium) | **Valid** in part | SR11 adopt by size + hash. The proposed hidden manifest on the SSD was rejected: it would add files visible on Windows to the user's archive. |
| 17 | Orphaned `._` files and leftover partials (Low-Medium) | **Valid** in part | Sweep only ledger-reserved partials (executor step 1). Stale tags from orphaned `._` files are corrected by the explicit tag/untag rule. FujiCull never deletes `._` files it didn't write. |
| 18 | Wording mismatches: R26 "listed", tags on Undecided, Trash names (Low) | **Valid** | Confirmation lists files; Undecided tags untouched; Trash paths recorded and shown |



# Cycle 2

_2026-10-09._

**Method:** a new fresh-context reviewer received the revised DESIGN §5.1, D6, D7, §5.3, §5.7, the ADR-003 decision and the contract (now including R27). Cross-model was offered again; the user chose to skip it.

**Result:** 28 findings. Several were caused by complexity that cycle 1 itself added: several sessions per card, adopt-by-hash, and an over-precise model of exFAT names. Reconciliation therefore **simplified** the design rather than adding rules. §5.1, §5.3 and §5.7 were rewritten around one principle: *FujiCull only removes files it can prove it wrote, or card files it was asked to delete; when in doubt it stops and asks.* Rule numbers were reissued as SR1–SR24.

| # | Finding | Classification | Resolution |
|---|---|---|---|
| 1 | Card swapped mid-session is never detected (Critical) | Valid | SR16: rescan at Apply start; volume UUID + file identity before every read and delete |
| 2 | Scanner drops HEIF, WAV, and anything outside `DCIM/*` (Critical) | Valid | SR1: whole-volume scan into frames / videos / other files; other files listed; HEIF warning |
| 3 | Adopt-by-hash makes foreign files eligible for the Trash (Critical) | Valid | Adopt-by-hash removed. Only `reserve` → `verified` chains are eligible (SR9, SR18). Lost journal → duplicates, accepted (SR23). |
| 4 | "Verified" may be served from cache; rename not durable on exFAT (Critical) | Valid | Write-side `F_NOCACHE`, directory `F_FULLFSYNC` before `verified`, Eject button (SR20) |
| 5 | FrameID relative to the chosen root (High) | Valid | SR2: relative to the volume root |
| 6 | A frame's own reservations count as taken; reservations never released (High) | Valid | SR11 reuse own reservation; `released` records; per-frame stop instead of whole-run deadlock |
| 7 | Superseded `verified` records; edited archive files re-copied as duplicates (High) | Valid | Latest record authoritative (SR15); gate offers Copy again / Cancel, never a silent re-copy (SR17) |
| 8 | Emptying `Google Photos/` breaks later runs (High) | Valid | Google Photos disposable: not in the gate, never recreated, not required for removal |
| 9 | All-or-nothing not atomic; records written after the group (High) | Valid | One record per file immediately after each operation; deletable-flag pre-check; split-pair handling (SR18, SR19) |
| 10 | Torn record mid-file (High) | Valid | Truncate a torn tail on open; other corruption stops and asks (SR15) |
| 11 | moveItem fallback can overwrite; the lock doesn't close the window (High) | Valid | `O_EXCL` placeholder claims the name; rename only over our own placeholder (SR10) |
| 12 | Permanent delete for any removable folder (High) | Valid | SR8: only a camera card (removable + `DCIM/` at root); everything else Trash or refuse |
| 13 | Only this session's ledger is read (Medium) | Valid | One session and journal per card; Start fresh archives the old one, and its files are never removable (SR4) |
| 14 | Videos have no identity (Medium) | Valid | Videos use the same per-file identity and journal records (SR9) |
| 15 | Adopt-by-hash can't live in a pure planner (Medium) | Valid | Moot: adopt-by-hash removed; crash-after-rename recovery happens in the executor |
| 16 | exFAT names fold case but don't normalise (Medium) | Valid | SR10: exact on-disk names; case-insensitive match without normalisation; ambiguity stops |
| 17 | Volume UUID checked after writing (Medium) | Valid | SR7: one checked directory descriptor, `*at()` calls |
| 18 | Free space under-counted (Medium) | Valid | SR14: allocation-rounded sizes + `._` + Google Photos + margin |
| 19 | Cancellation not checked during deletes (Medium) | Valid | Checked before every frame in steps 6 and 7 |
| 20 | Locked card vs archive removal ambiguous (Medium) | Valid | Removal runs and is recorded; card delete skipped |
| 21 | Fixed folder + restore can file a new trip under an old name (Medium) | Valid | D7 relaxed: folder pre-filled, can change for new keepers; partial-match prompt (SR4) |
| 22 | Google Photos copy from an edited archive JPG (Medium) | Valid | Made only in the same run, re-hashed against the card hash |
| 23 | Session lock only during Apply (Medium) | Valid | SR3: lock held while the card is open |
| 24 | Pairing collisions (Medium) | Valid | Split groups; orphans keep exact filenames (SR2) |
| 25 | Capture time missing on one side (Medium) | Valid | SR2: compared only when both sides have it |
| 26 | Trip-name validation incomplete (Low/Medium) | Valid | Full rule list in §5.7 |
| 27 | Untagging foreign files; inherited `._` tags (Low) | Valid | SR12: untag only files we tagged; our new files get exactly our tags |
| 28 | Wording and contradictions | Valid | Requirements Q11 wording fixed; scanner wording; ADR-003 updated; undo rule (SR21); confirm wording; SR3 divide-by-zero; folder-missing options; stray partials listed |

**Stop condition:** two cycles complete, with 0 of 46 findings classified as noise-only. The next step is either cycle 3 on the simplified design, or carrying the remaining fine-grained cases into the Apply tasks as test-first cases. That's the user's choice.
