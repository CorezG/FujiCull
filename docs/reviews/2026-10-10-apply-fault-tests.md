# Checkpoint D: what the Apply engine is tested against

_2026-10-10. For the owner's review before any screen is connected to Apply (tasks T16–T20)._

The Apply engine is the only part of FujiCull that copies, moves or deletes photos. This is the list of
things that can go wrong, what the engine does in each case, and the test that proves it. Every test runs
real file operations on small files in temporary folders; none touches a card, the archive drive or the
Trash. Test names are in the files under `Tests/FujiCullCoreTests/`.

192 tests cover this code (30 more exercise the file operations underneath). Seventeen safety rules were also
broken on purpose, one at a time, to confirm that at least one test fails each time (see the end).

## The one question

**Can a photo be lost?** A reject is deleted from the card only when all of these are true:

1. the copy run finished without stopping;
2. every keeper and every video is on the archive right now, with the size that was recorded;
3. every keeper file that this run did not itself copy still hashes to what was recorded;
4. every archive folder the journal refers to could be reached;
5. you confirmed.

The engine cannot delete without a "gate" object, and only the engine can make one, from its own check of
the archive.

## Copying one file (`SafeCopyTests`, 22 tests)

| What goes wrong | What happens | Test |
|---|---|---|
| The drive fills up or errors at any chunk | Copy fails; nothing is left on the archive | `aWriteErrorAtAnyChunkLeavesNothingBehind` |
| What is read back differs from what was written | Fails verification; nothing left | `aCorruptedReadBackFailsVerificationAndLeavesNothingBehind` |
| You cancel mid-copy, or during the read-back | Stops; nothing left | `cancellingBetweenChunksLeavesNothingBehind`, `cancellingDuringTheReadBackLeavesNothingBehind` |
| A file with that name already exists | Refused before any data is written; the existing file is untouched | `anExistingDestinationIsNeverOverwritten` |
| The same name in different capitals exists | Treated as taken, as the drive itself does | `aNameTheVolumeTreatsAsTheSameIsTaken` |
| A file appears with that name during the copy | Not overwritten | `aFileThatAppearsAtTheLastMomentIsNotOverwritten` |
| The drive refuses to force data to disk | The copy fails; it is never treated as "good enough" | `aFailedSyncFailsTheCopyAndIsNotDowngraded` |
| The card file isn't the size the scan saw | Not copied | `aSourceThatIsNotTheExpectedSizeIsNotCopied` |
| The archive JPG was edited before the Google Photos copy | Not copied | `aSourceThatNoLongerHashesToTheRecordedValueIsNotCopied` |
| A failure in the last steps (date, rename, final sync) | Nothing left: no placeholder, partial or half file | `aFailureInTheLastStepsLeavesNothingBehind` |
| The drive is unplugged mid-copy | The leftover is reported, for the next run to clear | `ifTheDriveGoesMidCopyThePartialIsReportedAsLeftBehind`, `ifTheDriveGoesBetweenTheClaimAndTheRenameAnEmptyPlaceholderIsLeft` |

## The journal (`LedgerTests`, 31 tests)

The journal is FujiCull's only proof of which archive files it wrote.

| What goes wrong | What happens | Test |
|---|---|---|
| The Mac dies while a record is being written | The half-written record is cut off; everything before it is intact. Tried at cut points all through a record. | `aCrashPartWayThroughAnAppendLosesOnlyThatRecord` |
| A line in the middle is damaged | Apply stops; the journal is not touched | `aDamagedLineInTheMiddleStopsEverythingAndTheJournalIsNotTouched` |
| A record claims a file was verified with no reservation before it | Ignored: the file never looks removable | `aVerifiedRecordWithoutAReservationIsIgnored` |
| A record claims a file was trashed with no intent before it | Ignored | `aTrashedRecordWithoutItsIntentIsIgnored` |
| A file replaced by a newer copy is asked to be trashed | Refused: superseded files are never removed | `aSupersededFileCanNeverBeTrashed` |

## Planning (`ApplyPlannerTests`, 45 tests)

| Situation | What is planned | Test |
|---|---|---|
| First run | Keepers and videos copied, rejects deleted, undecided left alone | `aFirstRunCopiesKeepersDeletesRejectsAndLeavesTheUndecidedAlone` |
| An undecided frame | Never mentioned in any operation | `anUndecidedFrameIsNeverMentionedInAnyOperation` |
| A card formatted and refilled: same file name and size, different photo | The new photo is copied; the old photo's archive files are never removed on its account | `aDifferentPhotoAtTheSamePathAndSizeIsCopiedNotSkipped`, `rejectingADifferentPhotoNeverRemovesTheOldPhotosArchiveFiles` |
| A reject with no capture date | Never deleted | `aRejectWithNoCaptureDateIsNeverDeleted` |
| The archive already has a file with that name, even only in Google Photos | The whole frame gets `-2`; nothing is overwritten | `aNameAlreadyOnTheArchiveGivesTheWholeFrameASuffix`, `aCollisionOnlyInGooglePhotosStillMovesTheWholeFrame` |
| Someone else's file sits where a half-copied frame's other file belongs | The frame is copied again whole under a new name; the old file is kept | `aForeignFileAtANeededNameRehomesTheWholeFrame` |
| A keeper rejected after archiving | Its archive copies are planned for the Trash, and only files the journal proves FujiCull wrote | `rejectingAnArchivedFrameRemovesItsArchiveFilesAndDeletesItFromTheCard`, `onlyFilesThisCardsJournalRecordsAreEverRemoved` |
| A favourite removed | Only a tag FujiCull set is removed; your own tags stay | `unfavouritingRemovesOnlyTagsFujiCullSet` |
| The card is locked | Copies and archive removals are planned; no deletes | `aLockedCardStillGetsCopiesAndArchiveRemovalsButNoDeletes` |
| Not enough space | Refused, with the numbers | `tooLittleSpaceStopsThePlanWithTheNumbers` |
| The card and the archive are the same drive | Refused | `archivingAVolumeOntoItselfIsRefused` |

## Copying, tagging and resuming (`ApplyExecutorCopyTests`, 32 tests)

| What goes wrong | What happens | Test |
|---|---|---|
| **The drive vanishes at any point in a run** | The next run finishes the job and the archive ends up exactly as an uninterrupted run leaves it: same names, same bytes, same tags, no `-2` duplicates. Tried at the first, middle and last call of every kind of file operation (every call at checkpoints). | `aRunCutOffAtAnyPointConvergesOnTheSameArchive` |
| Cut off between claiming a name and the rename | The empty placeholder and the partial are removed; the file is copied under its plain name | `aRunCutOffBetweenClaimingANameAndTheRenameIsCleanedUpAndFinished` |
| A copy finished but wasn't recorded | Recognised by hashing it against the card, and not copied again | `aCopyThatFinishedButWasNotRecordedIsAdoptedNotCopiedAgain` |
| A different file sits at a reserved name | Neither adopted nor removed | `aDifferentFileAtAReservedNameIsNeitherAdoptedNorRemoved` |
| A card file changed after the scan | That frame is skipped; the rest carry on | `aCardFileThatChangedSinceTheScanIsSkippedAndTheRestCarryOn` |
| A name is taken after planning | That frame is skipped, never overwrites, and is re-homed next time | `aNameTakenAfterPlanningSkipsTheFrameAndTheNextPlanRehomesIt` |
| The trip folder appears after it was planned as new | The run stops; nothing is added to it | `aFolderThatAppearsAfterItWasPlannedAsNewStopsTheRun` |
| An I/O error | The run stops; nothing later is attempted | `anIOErrorStopsTheRunAndNothingLaterIsAttempted` |
| Another drive is mounted where the archive should be | Refused | `anotherVolumeMountedWhereTheArchiveShouldBeIsRefused` |
| A different card is in the reader | Refused | `aCardThatIsNotTheOneTheSessionBelongsToIsRefused` |
| A keeper's archive file is missing or changed afterwards | The final check reports it instead of trusting the journal | `theFinalCheckReportsMissingChangedAndUnarchivedKeepers` |

## The gate, the Trash and the card (`ApplyExecutorDeleteTests`, 32 tests)

| What goes wrong | What happens | Test |
|---|---|---|
| **Any one file operation fails during copying** | A card file is only ever deleted if every keeper is on the archive byte for byte. Tried at the first, middle and last call of every kind of operation. | `noFailureDuringCopyingEverLeadsToADeleteWithoutEveryKeeperArchived` |
| The copy run stopped (full drive, failed sync, bad read-back, …) | Gate closed; zero files deleted | `aFailedCopyRunClosesTheGateAndNothingIsDeleted` |
| A keeper was skipped | Gate closed | `aSkippedKeeperClosesTheGate` |
| A keeper has gone missing from the archive | Gate closed | `aKeeperThatWentMissingFromTheArchiveClosesTheGate` |
| A keeper archived earlier has the right size but different contents | Gate closed | `aKeeperArchivedEarlierThatNoLongerHashesTheSameClosesTheGate` |
| A keeper is on a drive that isn't connected | Gate closed | `aKeeperOnADriveThatIsNotConnectedClosesTheGate` |
| You decline the confirmation | Nothing is deleted or even marked for deletion | `decliningTheConfirmationDeletesNothing` |
| A reject's card file changed since the scan | Its whole frame is skipped and reported | `aCardFileChangedSinceTheScanIsSkippedAndReported` |
| A reject's card file is locked | Its whole frame is skipped | `aLockedCardFileStopsItsWholeFrameFromBeingDeleted` |
| The second file of a pair can't be deleted | Reported as a split pair; finished on the next run | `ifTheSecondFileOfAPairCannotBeDeletedItIsReportedAndFinishedNextRun` |
| A plan (wrongly) names a keeper or an undecided frame for deletion | Refused: the engine checks the decision itself | `aPlanThatNamesAKeeperForDeletionIsRefused` |
| A plan (wrongly) names someone else's archive file for the Trash | Refused | `aPlanThatNamesSomeoneElsesArchiveFileForRemovalIsRefused` |
| An archive copy was edited since it was verified | Its frame is skipped and reported; the file stays | `anArchiveFileChangedSinceItWasVerifiedIsSkippedAndReported` |
| Moving to the Trash fails | The file stays. It is never deleted instead. | `aTrashMoveThatFailsIsNeverReplacedByADelete` |
| The app dies between a Trash move or delete and its record | Settled on the next run; no frame is stuck | `aTrashMoveThatHappenedButWasNotRecordedIsSettledAndTheFrameFinished`, `aDeleteThatHappenedButWasNotRecordedIsSettledOnTheNextRun` |
| The card is locked | No deletes; confirmed archive removals still happen | `aLockedCardKeepsItsRejectsButConfirmedArchiveRemovalsStillHappen` |
| The source isn't a camera card | Rejects go to the Trash, not deleted for good | `rejectsOnASourceThatIsNotACameraCardGoToTheTrashNotOblivion` |

## Rules broken on purpose

Each change below was made to the code, the tests were run, and at least one test failed; the change was then
undone.

| Area | Rule broken |
|---|---|
| Journal | Anyone can mark a file verified · a torn last line is not cut off · anything can be marked for the Trash |
| Planner | Capture time ignored · a reject deleted without a capture date · a re-appeared file binds to old records · names held in the journal reused |
| Recovery and copy | The empty placeholder not removed · a file adopted without hashing · a changed card file not noticed · a reservation released while leftovers remain |
| Gate and removal | The gate ignores missing keepers · the gate not enforced · a changed card file deleted anyway · another frame's archive file trashable · a non-reject deletable · the gate doesn't re-hash earlier copies |

## What the tests cannot show

- **Real hardware.** These run on the Mac's own disk. The exFAT behaviour they rely on was measured separately
  ([spike](../spikes/2026-10-10-exfat-fskit.md)), and the first run on a real card is the rehearsal on the
  throwaway card in phase 5.
- **A drive that lies about having flushed its cache**, and a rename torn by power loss on exFAT. Both are
  recorded as accepted trade-offs in DESIGN §5.7.
- **The screens.** Nothing is wired to the app yet.
