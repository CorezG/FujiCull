# Spike: what macOS's exFAT driver actually does (for Apply)

_2026-10-10. Run against a throwaway 96 MB exFAT disk image created with `hdiutil` in a scratch folder, never
against the card or the SSD. The image mounts through the same driver as both real volumes (`exfat … fskit`).
The only checks on real volumes were read-only identity queries. Probe sources: `scripts/spikes/exfat-probe/`._

The third doubt review of the Apply design raised questions that only measurement could settle.

## Results

| Question | Result | Consequence for Apply |
|---|---|---|
| Is `renameatx_np(RENAME_EXCL)` supported? | **No.** `errno 45` (not supported); `volumeSupportsExclusiveRenaming` is false. | The placeholder scheme stays: claim the final name with an exclusive create, then rename over our own placeholder. |
| Does `O_CREAT \| O_EXCL` refuse an existing name? | Yes (`EEXIST`). | It is the authority on whether a name is taken. |
| Does `F_FULLFSYNC` work on a file and on a directory descriptor? | Returns 0 on both. | Usable. A failure is treated as a failed copy, never downgraded. |
| Does a sync reach the device? | Without any sync, a new file's directory entry is **not** in the image; after `fsync` or `F_FULLFSYNC` on the file it **is**. | Syncs are effective on this driver. Whether a USB bridge honours the device flush can't be measured here. |
| Does the read-back verify from the device? | Written with `F_NOCACHE` on the **write** descriptor: yes. Bytes altered in the image behind the file system were seen by the next read, including the unaligned tail of an odd-sized file. | Step 2.5 is a real verification. |
| Is `F_NOCACHE` on the read side enough? | **No.** A file written without it was read back from the cache (alteration not seen), and once a file has been read, later `F_NOCACHE` reads are served from the cache too. | The write descriptor must have `F_NOCACHE`, and the read-back must be the first read of the partial. |
| Can the volume UUID be read from an open descriptor? | Yes, `fgetattrlist(ATTR_VOL_UUID)` on a directory descriptor; it equals `volumeUUIDString`. `fstatfs` has no UUID. | SR7 uses `fgetattrlist`. |
| How does the volume compare names? | `Trip` and `TRIP` are the same name. Precomposed and decomposed `é` are the **same** name. `ß` and `SS` are different names. | FujiCull never decides "exists" by its own case folding; it asks the volume. |
| Finder tags | Setting `tagNames` works; the tag is stored in a `._name` companion file (4 KB). Every file written gets a `._` companion. | Matches the space rule (one allocation unit per file). |
| Move to Trash (`FileManager.trashItem`) | Goes to the same volume's `.Trashes/501/`, returns the new URL, keeps the tag, and renames on a collision (`T.JPG 17-41-22-956.JPG`) instead of overwriting. | Usable for archive removal. |
| …with the volume mounted outside `/Volumes` and hidden from Finder | Fails with an I/O error; nothing is moved. | A failed Trash move skips the frame and is reported. It never falls back to deleting. |
| Timestamps | `futimens` works. | Step 2.6. |

## Identity facts from the real volumes (read-only)

| | `volumeIsInternal` | `volumeIsRemovable` | `volumeIsEjectable` | Format |
|---|---|---|---|---|
| SD card in the owner's reader (Fuji SD, and an 8 GB throwaway card) | false | **true** | true | exFAT (Fuji SD), FAT32 (throwaway) |
| C&J Archive (USB SSD) | false | **false** | false | exFAT |

So "removable" distinguishes a card in this reader from the SSD, and "external" means `volumeIsInternal == false`.

## A card formatted in the X-T50 can have no volume ID

The 8 GB throwaway card was formatted in the X-T50 and 27 RAW+JPEG frames were shot on it. Read-only checks:

| | Result |
|---|---|
| Format | FAT32 (the SD standard for cards up to 32 GB), volume name `NO NAME` |
| `volumeUUIDString` | **nil**. `diskutil` shows an all-zero UUID; `fgetattrlist(ATTR_VOL_UUID)` fails with `EINVAL`. |
| `volumeCreationDate` | The moment of the format by the camera's clock (the root, `FFDB` and `UPD` share it to the second). |
| Folders written | `DCIM/124_FUJI` (the folder and file numbers continue from the camera's counter), `FFDB`, `UPD` |

So the camera writes no volume serial on FAT32, and every small card it formats looks the same to macOS by name and ID. FujiCull keys such a card by capacity and format time instead (DESIGN §5.3). The 256 GB exFAT card does report a UUID; whether an in-camera exFAT format changes it is still unmeasured, and the design no longer depends on the answer (SR2).

## Not measured

- Whether the SSD's USB bridge really flushes its cache on `F_FULLFSYNC`. Mitigated by the Eject button and by the
  check of every keeper at the end of each run.
- Behaviour of a rename interrupted by power loss on exFAT. Recovery never trusts a file at a reserved name
  without hashing all of it.

## SafeCopy on real exFAT

After T16, the finished copy primitive was run against a 400 MB exFAT disk image with the five sample pairs
(scratch harness, not part of the test suite):

- Nine files copied; each hashed the same as its source when read back independently, and kept its date.
- The image then filled up. The copy failed with "no space left" and removed its partial: nothing was left.
- A second run refused every name that already existed and left no partial behind.
- No `fujicull-partial` name, or `._` companion of one, remained in the folder.
