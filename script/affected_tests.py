#!/usr/bin/env python3
"""Plan affected checks; never build, test or install. See docs/test-selection.md."""
import argparse
from fnmatch import fnmatchcase
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys

QUALIFICATION_TESTS = (
    'ChecklistCoreTests.TicketCleanupReceiptReadTests/testLatestSummaryPagesRetainFirstReceiptAndAreBoundedWithLargeItems',
    'ChecklistCoreTests.TestStoreTests/testWarmStoreSetupReportsPairedMedians',
    'ChecklistCoreTests.MediaListQueryTests/testExamplesStayCollapsedUntilShowThenCapPageAndNeverGrantApproval',
    'ChecklistIPCTests.LongCommandTests/testCommandLongerThanOldDeadlineReturnsCommittedResultThroughRealClient',
    'ChecklistAppTests.IsolatedDefaultsTests/testPreferencesRemainAbsentAfterChildProcessExit',
    'ChecklistCoreTests.StorageSnapshotCapacityTests/testMoreThanThirtyThousandObjectsAndEightMiBManifestRoundTripWithoutPruning',
    'ChecklistCoreTests.MediaFrozenIntakeTests/test300SourcePreviewExactConfirmationStop200Resume96AndPlanRevision',
    'ChecklistCoreTests.MediaDecisionTests/test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal',
    'ChecklistCoreTests.EvidenceAuthorityTests/testWorkHealthLargeProjectDecodesOnlyCandidatePage',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testPreparationProgressUnderConstantUnrelatedWritesAndBoundsMemory',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testBackupDescriptorStreamingHasBoundedAllocations',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testProjectedReferenceScanBoundsWorkWithManyOwnedTokens',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testSustainedWritersBoundRSSCPUAndBackoff',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testSelectedPayloadAndHistoryPreparationHasBoundedPeak',
    'ChecklistCoreTests.CoreTests/testEpicDeleteRealSizeBackfillResumesExpiredSlices',
    'ChecklistCoreTests.CoreTests/testEpicDeleteIndexedThirtyThousandRecordsAndEventsAndConcurrentRead',
    'ChecklistCoreTests.MediaListQueryTests/testThousandItemBoundedGroupedPagesFreezeOrderAcrossInsertsAndUpdates',
    'ChecklistCoreTests.ScreenReadPerformanceTests/testRealSizeScreenReads',
    'ChecklistCoreTests.ScreenReadPerformanceTests/testOverviewWithRetainedReviewHistory',
    'ChecklistCoreTests.ScreenReadQueryPlanTests/testRealSizeScreenReadQueryPlans',
    'ChecklistCoreTests.OverviewReadOptimizationTests/testReadOnlyBatchClaimProjectionProfile',
    'ChecklistCoreTests.ClaimPathOptimizationTests/testReadOnlyClaimComponentProfile',
    'ChecklistCoreTests.OverviewReadOptimizationTests/testReadOnlyOverviewQueryProfile',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testLargeAutomaticFirstPassKeepsConcurrentReadAndWriteUnderTwoSeconds',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testLargeCacheAliasInventoryExhaustsOneBoundedClosureBudgetAndRetainsEntry',
    'ChecklistCoreTests.MediaRoundTests/testLargeRetainedHistoryDoesNotHoldWriterDuringPreparation',
    'ChecklistCoreTests.StorageReadPerformanceTests/testDeliveryPassLookupTimingAtFiveThousandRecords',
    'ChecklistCoreTests.ArchivePreviewPerformanceTests/testFourFourHundredFileCapturesKeepExactPreviewUnderOneSecond',
    'ChecklistCoreTests.EvidenceAuthorityTests/testLargeSubmitBlocksOtherCommandsOnlyBriefly',
    'ChecklistCoreTests.EvidenceAuthorityTests/testLargeReferenceImportBlocksOtherCommandsOnlyBriefly',
    'ChecklistCoreTests.EvidenceAuthorityTests/testReviewClaimValidatesTheCapturedTargetBeforeTheWriter',
)
# Methods that assert a wall-clock budget, regardless of its size.
# They keep their assertions unchanged but leave the parallel default pass and run in
# one separate single-worker SwiftPM invocation, without sibling test work
# competing for a frame or deadline budget (CL-275).
# scripts/test_affected_tests.py fails when wall_clock_budget_cases finds an
# ungated case missing here or in QUALIFICATION_TESTS.
TIMING_TESTS = (
    'ChecklistAppTests.ApplicationTerminationTests/testOpenFloatingCaptureQuitsAndRestoresBlankTextAndFiles',
    'ChecklistAppTests.CachedScreenReturnTests/testTemplateCatalogOverviewReturnNeedsNoReadOrCatalogReplay',
    'ChecklistCoreTests.EvidenceAuthorityTests/testGitCallsAreBoundedAndReadBothPipes',
    'ChecklistCoreTests.ArchivePreviewStoreCopyTests/testCL24PreviewOnOwnedStoreCopy',
    'ChecklistCoreTests.ScreenReadPerformanceTests/testOwnedStoreMeasurements',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testDefaultsStartAutomaticallyWithoutPreviewOrActivationIncludingRestart',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testSchemaThreeStartupWithProtectedSnapshotsSeveralProjectsAndCacheArmsWithoutOtherWork',
    'ChecklistCoreTests.TriageListTimingTests/testProjectedRealSizeTriagesWithinServiceBudget',
    'ChecklistAppTests.HumanClaimsKeychainTests/testForeignACLReadReturnsNilWithinTwoSecondsInTemporaryKeychain',
    'ChecklistAppTests.OverviewReadRecoveryTests/testCachedOverviewReturnRestoresMatchingGroupsSynchronously',
    'ChecklistAppTests.OwnedStoreScreenCacheTests/testRealBackupColdOverviewAndCachedNavigation',
    'ChecklistAppTests.RecordOrderingTests/testFiftyCoarseMessagesSortWithinFrameBudget',
    'ChecklistAppTests.ScopedWorkspaceReadTests/testCachedProjectSwitchRestoresTicketsBeforeBackgroundReply',
    'ChecklistAppTests.ScreenTimingTests/testCachedCleanupNativeFrame',
    'ChecklistAppTests.ScreenTimingTests/testCachedEpicsNativeFrame',
    'ChecklistAppTests.ScreenTimingTests/testCachedOverviewNativeFrame',
    'ChecklistAppTests.ScreenTimingTests/testCachedProjectSwitchNativeFrame',
    'ChecklistAppTests.ScreenTimingTests/testCachedTicketDetailNativeFrame',
    'ChecklistAppTests.ScreenTimingTests/testCachedTicketsWithTriagesNativeFrame',
    'ChecklistAppTests.ScreenTimingTests/testColdCleanupNativeFrame',
    'ChecklistCoreTests.CoreTests/testReadMethodsDoNotWaitForTheWriteLock',
    'ChecklistCoreTests.ScreenReadPerformanceTests/testReadOnlyBackupScreenMeasurements',
    'ChecklistCoreTests.StorageBackupConcurrencyTests/testNotesEditsAndNewImportsFinishWhileCopyAndVerificationArePaused',
    'ChecklistCoreTests.StorageFolderAccessTests/testBlockedBackupDestinationEndsReleasesRetentionAndSameIDRetryCompletes',
    'ChecklistCoreTests.StorageFolderAccessTests/testBlockedBackupSourceEndsReleasesRetentionAndSameIDRetryCompletes',
    'ChecklistCoreTests.StorageFolderAccessTests/testBlockedManagedOwnerAnswerEndsBeforeSourceObservationAndRetryCommitsOnce',
    'ChecklistCoreTests.StorageFolderAccessTests/testBlockedRootOpenEndsAndReapsChild',
    'ChecklistCoreTests.StorageFolderAccessTests/testFIFOIsRefusedWithoutBlockingOnFinalOpen',
    'ChecklistCoreTests.StorageFolderAccessTests/testTimedOutUncommittedImportRetainsIntentAndSameIDRetryCommitsOnceAfterRestart',
    'ChecklistCoreTests.TicketCleanupReceiptMeasurementTests/testOwnedStoreReceiptRead',
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testLargeFileVerificationYieldsWriterAndChangedPinnedFileIsRetained',
    'ChecklistIPCTests.AsyncServiceCallTests/testMissingReplyReachesAsyncCallerAtItsDeadline',
)
# Load-sensitive cases without a wall-clock budget (a cancel-versus-copy race and an
# idle-CPU bound); they run in the same single-worker command as TIMING_TESTS.
LOAD_SENSITIVE_TESTS = (
    'ChecklistAppTests.PreviewAvailabilityTests/testActiveCopyCancelButtonShowsAccessibleCanceledOutcome',
    # Ordering checks on 50 ms fake replies race at load ~150 (O177 run, 24 Oct 2026; CL-275).
    'ChecklistAppTests.ScreenTimingTests/testAutomaticOverviewRefreshRetainsValidRowsAndCountsUntilEachReply',
)
# Real-size fixtures without a timing assertion also belong at qualification
# level. Keep their original source and coverage out of ordinary unit runs.
REAL_SIZE_TESTS = (
    'ChecklistCoreTests.StorageCompactManifestTests/testTwoHundredThousandObjectTemplateFitsManifestBudgetWithoutLosingDescriptors',
)
QUALIFICATION_CASES = QUALIFICATION_TESTS + REAL_SIZE_TESTS
# Qualification fixture audit (CL-294). Exact shared startup/record inputs and
# case-specific command paths include extension fixtures, rather than inferring
# fixtures from XCTest class names. Patterns use repository-relative paths.
def _core_paths(names):
    return tuple('Sources/ChecklistCore/' + name + '.swift' for name in names.split())


QUALIFICATION_STORE_PATHS = _core_paths(
    'EpicReferenceIndex FileDurability GRDBRecordEnvelopeAdapter GRDBTransactionAdapter '
    'LegacyStoredValue ManagedPaths Models OrphanFileCleanup PublicErrorText ReadSnapshotCache '
    'RecordEnvelope RecordPruning Router SchemaMigrations SnapshotReadProjection SourceCapture '
    'StorageAdmission StorageBootstrap StorageFolderAccess StorageMaintenance StorageObjectFiles '
    'StorageRecovery StorageStatus Store StoredRecord '
) + (
    'Packages/ChecklistShared/Sources/ChecklistContracts/*',
    'Packages/ChecklistShared/Sources/ChecklistDomain/*',
    'Sources/ChecklistProviders/BundledProviderPlugins.swift',
    'Sources/ChecklistProviders/ProviderPlugin.swift',
    'Tests/ChecklistTestSupport/*',
)
QUALIFICATION_SOURCE_PATHS = {
    # Synthetic storage_job receipts, project_create and paged ticket_cleanup_receipts. Does not execute cleanup preparation/deletion.
    'ChecklistCoreTests.TicketCleanupReceiptReadTests/testLatestSummaryPagesRetainFirstReceiptAndAreBoundedWithLargeItems': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog TicketCleanupReceiptRead TicketObjectDeletion WorkspaceProjectCreation '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupReceiptReadTests.swift',
    ),
    # 25 paired TestStore.router vs fresh CommandRouter opens; startup protected snapshots/admission/migration, maintenance and close/checkpoint. No feature commands.
    'ChecklistCoreTests.TestStoreTests/testWarmStoreSetupReportsPairedMedians': QUALIFICATION_STORE_PATHS + _core_paths(
        'ManagedAttachmentImport SourceExport StorageRestore StorageSnapshot '
        'StorageSnapshotAuthority StorageSnapshotRetention '
    ) + (
        'Tests/ChecklistCoreTests/TestStoreTests.swift',
    ),
    # Media Fixture type adoption/round/item/context publication and real router commands; MediaList cases page/freeze/count/read leases, FrozenIntake captures/preview/confirms/resumes sources, decisions bulk prepare/apply/reverse, round case updates retained history.
    'ChecklistCoreTests.MediaListQueryTests/testExamplesStayCollapsedUntilShowThenCapPageAndNeverGrantApproval': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog ConnectionRegistration MediaCommandPreparation MediaDecisions MediaIntake '
        'MediaIntakeMapping MediaListConfiguration MediaListQueries MediaOwnerChannel '
        'MediaRecordRegistry MediaReviewContext MediaReviewSchema MediaRounds Policy '
        'PolicySnapshots ProjectSettings WorkspaceProjectCreation '
    ) + (
        'Tests/ChecklistCoreTests/MediaListQueryTests.swift',
        'Tests/ChecklistCoreTests/MediaRoundTests.swift',
        'Tests/ChecklistCoreTests/StorageConsistencyTests.swift',
    ),
    # Anonymous NSXPCListener -> ChecklistClient.requestOnce -> MacOSLocalCommandTransport -> delayed project_create + command replay. No installed authentication/bootstrap/service launch.
    'ChecklistIPCTests.LongCommandTests/testCommandLongerThanOldDeadlineReturnsCommittedResultThroughRealClient': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog Policy ProjectSettings StarterFields WorkspaceProjectCreation '
    ) + (
        'Sources/ChecklistIPC/ChecklistClient.swift',
        'Sources/ChecklistIPC/CommandReply.swift',
        'Sources/ChecklistIPC/LocalPlatformServices.swift',
        'Sources/ChecklistIPC/Protocol.swift',
        'Tests/ChecklistIPCTests/LongCommandTests.swift',
    ),
    # Child xctest constructs WorkspaceWindowStorage/State and ChecklistStore with injected no-request transport and denied alerts; only memory preferences + draft/navigation/window initialization. Does not exercise Media SwiftUI views.
    'ChecklistAppTests.IsolatedDefaultsTests/testPreferencesRemainAbsentAfterChildProcessExit': (
        'Sources/ChecklistApp/Media/MediaReviewModel.swift',
        'Sources/ChecklistApp/Models/WorkspaceObservation.swift',
        'Sources/ChecklistApp/Stores/ChecklistStore.swift',
        'Sources/ChecklistApp/Support/CaptureTermination.swift',
        'Sources/ChecklistApp/Support/DesktopAlerts.swift',
        'Sources/ChecklistApp/Support/DetailItemStateRetention.swift',
        'Sources/ChecklistApp/Support/DisplayCaches.swift',
        'Sources/ChecklistApp/Support/DraftFileStorage.swift',
        'Sources/ChecklistApp/Support/LocalDraftPersistence.swift',
        'Sources/ChecklistApp/Support/PendingCommandRecovery.swift',
        'Sources/ChecklistApp/Support/ProductionGroups.swift',
        'Sources/ChecklistApp/Support/ScreenTiming.swift',
        'Sources/ChecklistApp/Support/WorkspaceWindowRoot.swift',
        'Sources/ChecklistApp/Views/TicketCleanupSettingsSection.swift',
        'Sources/ChecklistIPC/ChecklistInstance.swift',
        'Tests/ChecklistAppTests/IsolatedDefaults.swift',
        'Tests/ChecklistAppTests/IsolatedDefaultsTests.swift',
        'Tests/ChecklistTestSupport/*',
    ),
    # Fixture.ownerBackup with >30k symlinks -> inventory, durable publication, compact/legacy manifest, reconcile, lost-SQL-receipt recovery, changed-file refusal.
    'ChecklistCoreTests.StorageSnapshotCapacityTests/testMoreThanThirtyThousandObjectsAndEightMiBManifestRoundTripWithoutPruning': QUALIFICATION_STORE_PATHS + _core_paths(
        'ManagedPathConsumers MediaRecordRegistry StorageCompactManifest StorageRestore '
        'StorageSnapshot StorageSnapshotAuthority StorageSnapshotRetention '
    ) + (
        'Tests/ChecklistCoreTests/StorageSnapshotCapacityTests.swift',
    ),
    # Media Fixture type adoption/round/item/context publication and real router commands; MediaList cases page/freeze/count/read leases, FrozenIntake captures/preview/confirms/resumes sources, decisions bulk prepare/apply/reverse, round case updates retained history.
    'ChecklistCoreTests.MediaFrozenIntakeTests/test300SourcePreviewExactConfirmationStop200Resume96AndPlanRevision': QUALIFICATION_STORE_PATHS + _core_paths(
        'Attachments Catalog ConnectionRegistration ManagedAttachmentImport MediaCommandPreparation '
        'MediaDecisions MediaIntake MediaIntakeMapping MediaListConfiguration MediaListQueries '
        'MediaOwnerChannel MediaRecordRegistry MediaReviewContext MediaReviewSchema MediaRounds '
        'Policy PolicySnapshots ProjectSettings ReferenceImportPreparation WorkspaceProjectCreation '
    ) + (
        'Tests/ChecklistCoreTests/MediaFrozenIntakeTests.swift',
        'Tests/ChecklistCoreTests/MediaRoundTests.swift',
        'Tests/ChecklistCoreTests/StorageConsistencyTests.swift',
    ),
    # Media Fixture type adoption/round/item/context publication and real router commands; MediaList cases page/freeze/count/read leases, FrozenIntake captures/preview/confirms/resumes sources, decisions bulk prepare/apply/reverse, round case updates retained history.
    'ChecklistCoreTests.MediaDecisionTests/test450SelectionLostReplyFailedMiddleOnlyRefreshAndLaterReversal': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog ConnectionRegistration MediaCommandPreparation MediaDecisions MediaOwnerChannel '
        'MediaRecordRegistry MediaReviewContext MediaReviewSchema MediaRounds Policy '
        'PolicySnapshots ProjectSettings WorkspaceProjectCreation '
    ) + (
        'Tests/ChecklistCoreTests/MediaDecisionTests.swift',
        'Tests/ChecklistCoreTests/MediaRoundTests.swift',
        'Tests/ChecklistCoreTests/StorageConsistencyTests.swift',
    ),
    # EvidenceAuthority fixture builds actual verified test worker, ready task and claim; 20,001 tasks then runWorkHealthChecks and candidate-page decoder count.
    'ChecklistCoreTests.EvidenceAuthorityTests/testWorkHealthLargeProjectDecodesOnlyCandidatePage': QUALIFICATION_STORE_PATHS + _core_paths(
        'AcceptanceEvidence AgentReference AgentReviews AttachmentOwnership Attachments '
        'AuthorizedFileReadAdapter BatchClaimContext Communication ConnectionRegistration '
        'DirectionContext EvidenceMeasures GroupKeys Groups HumanRequestFilePreparation ListFields '
        'ManagedAttachmentImport NativeCommunicationRoutes Policy PolicySnapshots ProjectSettings '
        'ReferenceImportPreparation Relations RequiredEpic ReviewBatchInputs ReviewDrafts '
        'ReviewEvidence ReviewOutcomes ReviewRequirementIntegration ReviewRequirements '
        'ReviewReturns SafeFileRead ScopedMentionProjection ScopedTaskRecords SelectedTicketRead '
        'SourceExport SourceGitProcessAdapter StarterFields TaskContext TaskRecordSelection '
        'TaskReferenceValidation TaskSessions TaskStatusReason TicketChangeCoverage '
        'TicketPageFilters TicketPageRead TriageCommandEffects Work WorkAuthority WorkHealth '
        'WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/EvidenceAuthorityTests.swift',
        'Tests/ChecklistCoreTests/WorkHealthTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions. Ordinary-note traffic executes the mention parser through Communication.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testPreparationProgressUnderConstantUnrelatedWritesAndBoundsMemory': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AssistantGrants '
        'AttachmentOwnership Attachments Catalog Communication EvidenceMeasures '
        'ManagedPathConsumers NativeCommunicationRoutes OrdinaryMentionCommands '
        'OrdinaryMentionTokens OrdinaryMentions SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work WorkAuthority '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testBackupDescriptorStreamingHasBoundedAllocations': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AttachmentOwnership '
        'Attachments Catalog Communication EvidenceMeasures ManagedPathConsumers '
        'NativeCommunicationRoutes SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testProjectedReferenceScanBoundsWorkWithManyOwnedTokens': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AttachmentOwnership '
        'Attachments Catalog Communication EvidenceMeasures ManagedPathConsumers '
        'NativeCommunicationRoutes SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions. Ordinary-note traffic executes the mention parser through Communication.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testSustainedWritersBoundRSSCPUAndBackoff': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AssistantGrants '
        'AttachmentOwnership Attachments Catalog Communication EvidenceMeasures '
        'ManagedPathConsumers NativeCommunicationRoutes OrdinaryMentionCommands '
        'OrdinaryMentionTokens OrdinaryMentions SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work WorkAuthority '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testSelectedPayloadAndHistoryPreparationHasBoundedPeak': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AttachmentOwnership '
        'Attachments Catalog Communication EvidenceMeasures ManagedPathConsumers '
        'NativeCommunicationRoutes SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # CoreTests fixture; large records/events and epic_create/epic_delete/service_info; indexed references, resumable backfill and concurrent read.
    'ChecklistCoreTests.CoreTests/testEpicDeleteRealSizeBackfillResumesExpiredSlices': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog EpicDeletion GroupKeys Groups Policy ProjectSettings Relations RequiredEpic '
        'TaskContext TaskReferenceValidation TaskSessions Work '
    ) + (
        'Tests/ChecklistCoreTests/CoreTests.swift',
        'Tests/ChecklistCoreTests/EpicDeletionTests.swift',
        'Tests/ChecklistCoreTests/RequiredEpicFixture.swift',
    ),
    # CoreTests fixture; large records/events and epic_create/epic_delete/service_info; indexed references, resumable backfill and concurrent read.
    'ChecklistCoreTests.CoreTests/testEpicDeleteIndexedThirtyThousandRecordsAndEventsAndConcurrentRead': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog EpicDeletion GroupKeys Groups Policy ProjectSettings Relations RequiredEpic '
        'TaskContext TaskReferenceValidation TaskSessions Work '
    ) + (
        'Tests/ChecklistCoreTests/CoreTests.swift',
        'Tests/ChecklistCoreTests/EpicDeletionTests.swift',
        'Tests/ChecklistCoreTests/RequiredEpicFixture.swift',
    ),
    # Media Fixture type adoption/round/item/context publication and real router commands; MediaList cases page/freeze/count/read leases, FrozenIntake captures/preview/confirms/resumes sources, decisions bulk prepare/apply/reverse, round case updates retained history.
    'ChecklistCoreTests.MediaListQueryTests/testThousandItemBoundedGroupedPagesFreezeOrderAcrossInsertsAndUpdates': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog ConnectionRegistration MediaCommandPreparation MediaDecisions MediaIntake '
        'MediaIntakeMapping MediaListConfiguration MediaListQueries MediaOwnerChannel '
        'MediaRecordRegistry MediaReviewContext MediaReviewSchema MediaRounds Policy '
        'PolicySnapshots ProjectSettings WorkspaceProjectCreation '
    ) + (
        'Tests/ChecklistCoreTests/MediaListQueryTests.swift',
        'Tests/ChecklistCoreTests/MediaRoundTests.swift',
        'Tests/ChecklistCoreTests/StorageConsistencyTests.swift',
    ),
    # ReadPerformanceFixture seeds real-size task/group/history rows; screen workspace/task/triage queries or read-only component profiles invoke projection/context/prerequisite/claim category helpers.
    'ChecklistCoreTests.ScreenReadPerformanceTests/testRealSizeScreenReads': QUALIFICATION_STORE_PATHS + _core_paths(
        'AgentReference BatchClaimContext BatchDisposition Batches Catalog Communication '
        'CompletionPreview DirectionContext EvidenceMeasures GroupKeys Groups ListFields Policy '
        'PolicySnapshots ProjectSettings Relations Requests RequiredEpic ReviewOutcomes '
        'ReviewRequirementIntegration ReviewRequirements ScopedMentionProjection ScopedTaskRecords '
        'SelectedTicketRead StarterFields TaskContext TaskRecordSelection TaskReferenceValidation '
        'TaskSessions TaskStatusReason TicketPageFilters TicketPageRead TriageCommandEffects '
        'TriageTransitions Work WorkAuthority WorkHealth WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/ScreenReadPerformanceTests.swift',
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # ReadPerformanceFixture seeds real-size task/group/history rows; screen workspace/task/triage queries or read-only component profiles invoke projection/context/prerequisite/claim category helpers.
    'ChecklistCoreTests.ScreenReadPerformanceTests/testOverviewWithRetainedReviewHistory': QUALIFICATION_STORE_PATHS + _core_paths(
        'AgentReference BatchClaimContext BatchDisposition Batches Catalog Communication '
        'CompletionPreview DirectionContext EvidenceMeasures GroupKeys Groups ListFields Policy '
        'PolicySnapshots ProjectSettings Relations Requests RequiredEpic ReviewOutcomes '
        'ReviewRequirementIntegration ReviewRequirements ScopedMentionProjection ScopedTaskRecords '
        'SelectedTicketRead StarterFields TaskContext TaskRecordSelection TaskReferenceValidation '
        'TaskSessions TaskStatusReason TicketPageFilters TicketPageRead TriageCommandEffects '
        'TriageTransitions Work WorkAuthority WorkHealth WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/ScreenReadPerformanceTests.swift',
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # ReadPerformanceFixture seeds real-size task/group/history rows; screen workspace/task/triage queries or read-only component profiles invoke projection/context/prerequisite/claim category helpers.
    'ChecklistCoreTests.ScreenReadQueryPlanTests/testRealSizeScreenReadQueryPlans': QUALIFICATION_STORE_PATHS + _core_paths(
        'AgentReference BatchClaimContext BatchDisposition Batches Catalog Communication '
        'CompletionPreview DirectionContext EvidenceMeasures GroupKeys Groups ListFields Policy '
        'PolicySnapshots ProjectSettings Relations Requests RequiredEpic ReviewOutcomes '
        'ReviewRequirementIntegration ReviewRequirements ScopedMentionProjection ScopedTaskRecords '
        'SelectedTicketRead StarterFields TaskContext TaskRecordSelection TaskReferenceValidation '
        'TaskSessions TaskStatusReason TicketPageFilters TicketPageRead TriageCommandEffects '
        'TriageTransitions Work WorkAuthority WorkHealth WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/ScreenReadQueryPlanTests.swift',
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # ReadPerformanceFixture seeds real-size task/group/history rows; screen workspace/task/triage queries or read-only component profiles invoke projection/context/prerequisite/claim category helpers.
    'ChecklistCoreTests.OverviewReadOptimizationTests/testReadOnlyBatchClaimProjectionProfile': QUALIFICATION_STORE_PATHS + _core_paths(
        'AgentReference BatchClaimContext BatchDisposition Batches Catalog Communication '
        'CompletionPreview DirectionContext EvidenceMeasures GroupKeys Groups ListFields Policy '
        'PolicySnapshots ProjectSettings Relations Requests RequiredEpic ReviewOutcomes '
        'ReviewRequirementIntegration ReviewRequirements ScopedMentionProjection ScopedTaskRecords '
        'SelectedTicketRead StarterFields TaskContext TaskRecordSelection TaskReferenceValidation '
        'TaskSessions TaskStatusReason TicketPageFilters TicketPageRead TriageCommandEffects '
        'TriageTransitions Work WorkAuthority WorkHealth WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/OverviewReadOptimizationTests.swift',
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # ReadPerformanceFixture seeds real-size task/group/history rows; screen workspace/task/triage queries or read-only component profiles invoke projection/context/prerequisite/claim category helpers.
    'ChecklistCoreTests.ClaimPathOptimizationTests/testReadOnlyClaimComponentProfile': QUALIFICATION_STORE_PATHS + _core_paths(
        'AgentReference BatchClaimContext BatchDisposition Batches Catalog Communication '
        'CompletionPreview DirectionContext EvidenceMeasures GroupKeys Groups ListFields Policy '
        'PolicySnapshots ProjectSettings Relations Requests RequiredEpic ReviewOutcomes '
        'ReviewRequirementIntegration ReviewRequirements ScopedMentionProjection ScopedTaskRecords '
        'SelectedTicketRead StarterFields TaskContext TaskRecordSelection TaskReferenceValidation '
        'TaskSessions TaskStatusReason TicketPageFilters TicketPageRead TriageCommandEffects '
        'TriageTransitions Work WorkAuthority WorkHealth WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/ClaimPathOptimizationTests.swift',
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # ReadPerformanceFixture seeds real-size task/group/history rows; screen workspace/task/triage queries or read-only component profiles invoke projection/context/prerequisite/claim category helpers.
    'ChecklistCoreTests.OverviewReadOptimizationTests/testReadOnlyOverviewQueryProfile': QUALIFICATION_STORE_PATHS + _core_paths(
        'AgentReference BatchClaimContext BatchDisposition Batches Catalog Communication '
        'CompletionPreview DirectionContext EvidenceMeasures GroupKeys Groups ListFields Policy '
        'PolicySnapshots ProjectSettings Relations Requests RequiredEpic ReviewOutcomes '
        'ReviewRequirementIntegration ReviewRequirements ScopedMentionProjection ScopedTaskRecords '
        'SelectedTicketRead StarterFields TaskContext TaskRecordSelection TaskReferenceValidation '
        'TaskSessions TaskStatusReason TicketPageFilters TicketPageRead TriageCommandEffects '
        'TriageTransitions Work WorkAuthority WorkHealth WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/OverviewReadOptimizationTests.swift',
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions. Ordinary-note traffic executes the mention parser through Communication.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testLargeAutomaticFirstPassKeepsConcurrentReadAndWriteUnderTwoSeconds': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AssistantGrants '
        'AttachmentOwnership Attachments Catalog Communication EvidenceMeasures '
        'ManagedPathConsumers NativeCommunicationRoutes OrdinaryMentionCommands '
        'OrdinaryMentionTokens OrdinaryMentions SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work WorkAuthority '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # TicketLifecycleCleanup fixture (base test file plus contention extension), targeted preparation/inventory/commit or automatic maintenance; fixture helpers create ready/claimed/submitted tickets and source cache executions.
    'ChecklistCoreTests.TicketLifecycleCleanupTests/testLargeCacheAliasInventoryExhaustsOneBoundedClosureBudgetAndRetainsEntry': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupExecutor ArchiveCleanupJob ArchiveCleanupJobs '
        'ArchiveCleanupObservation ArchiveCleanupReferences ArchiveRetention AttachmentOwnership '
        'Attachments Catalog Communication EvidenceMeasures ManagedPathConsumers '
        'NativeCommunicationRoutes SafeFileRead SourceBuildCacheCleanup SourceExport '
        'StorageCompactManifest StorageSnapshotAuthority StorageSnapshotRetention TaskContext '
        'TaskSessions TicketCleanupFence TicketCleanupInventory TicketCleanupPreparation '
        'TicketCleanupReceiptRead TicketLifecycleCleanup TicketObjectDeletion TicketPurge '
        'TicketRetirement Work '
    ) + (
        'Tests/ChecklistCoreTests/TicketCleanupContentionTests.swift',
        'Tests/ChecklistCoreTests/TicketLifecycleCleanupTests.swift',
    ),
    # Media Fixture type adoption/round/item/context publication and real router commands; MediaList cases page/freeze/count/read leases, FrozenIntake captures/preview/confirms/resumes sources, decisions bulk prepare/apply/reverse, round case updates retained history.
    'ChecklistCoreTests.MediaRoundTests/testLargeRetainedHistoryDoesNotHoldWriterDuringPreparation': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog ConnectionRegistration MediaCommandPreparation MediaDecisions MediaOwnerChannel '
        'MediaRecordRegistry MediaReviewContext MediaReviewSchema MediaRounds Policy '
        'PolicySnapshots ProjectSettings WorkspaceProjectCreation '
    ) + (
        'Tests/ChecklistCoreTests/MediaRoundTests.swift',
        'Tests/ChecklistCoreTests/StorageConsistencyTests.swift',
    ),
    # ReadPerformanceFixture seeded 5k records; repeated GRDBRecordEnvelopeAdapter session lookups and bridge(delivery_pending) revoked-recipient filtering.
    'ChecklistCoreTests.StorageReadPerformanceTests/testDeliveryPassLookupTimingAtFiveThousandRecords': QUALIFICATION_STORE_PATHS + _core_paths(
        'Catalog Communication ConnectionRegistration NativeCommunicationRoutes '
        'NativeDeliveryStatus WorkAuthority '
    ) + (
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # ReadPerformanceFixture seeds capture/manifest/attachment records; calls attachment_cleanup_preview twice, checks exact clean/retained/held bytes.
    'ChecklistCoreTests.ArchivePreviewPerformanceTests/testFourFourHundredFileCapturesKeepExactPreviewUnderOneSecond': QUALIFICATION_STORE_PATHS + _core_paths(
        'ArchiveCleanupConfiguration ArchiveCleanupObservation ArchiveCleanupReferences '
        'ArchiveRetention AttachmentOwnership Attachments Catalog ManagedPathConsumers TaskContext '
        'Work '
    ) + (
        'Tests/ChecklistCoreTests/StorageReadPerformanceTests.swift',
    ),
    # EvidenceAuthority base fixture + writer-lock extension; real source capture/submit or large reference attachment or captured-target review claim, with concurrent message_send/task_list probes. Ordinary-note traffic executes the mention parser through Communication.
    'ChecklistCoreTests.EvidenceAuthorityTests/testLargeSubmitBlocksOtherCommandsOnlyBriefly': QUALIFICATION_STORE_PATHS + _core_paths(
        'AcceptanceEvidence AgentReference AgentReviews AssistantGrants AttachmentOwnership '
        'Attachments AuthorizedFileReadAdapter BatchClaimContext Communication '
        'ConnectionRegistration DirectionContext EvidenceMeasures GroupKeys Groups '
        'HumanRequestFilePreparation ListFields ManagedAttachmentImport NativeCommunicationRoutes '
        'OrdinaryMentionCommands OrdinaryMentionTokens OrdinaryMentions Policy PolicySnapshots '
        'ProjectSettings ReferenceImportPreparation Relations RequiredEpic ReviewBatchInputs '
        'ReviewDrafts ReviewEvidence ReviewOutcomes ReviewRequirementIntegration ReviewRequirements '
        'ReviewReturns SafeFileRead ScopedMentionProjection ScopedTaskRecords SelectedTicketRead '
        'SourceExport SourceGitProcessAdapter StarterFields TaskContext TaskRecordSelection '
        'TaskReferenceValidation TaskSessions TaskStatusReason TicketChangeCoverage '
        'TicketPageFilters TicketPageRead TriageCommandEffects Work WorkAuthority WorkHealth '
        'WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/EvidenceAuthorityTests.swift',
        'Tests/ChecklistCoreTests/WriterLockTests.swift',
    ),
    # EvidenceAuthority base fixture + writer-lock extension; real source capture/submit or large reference attachment or captured-target review claim, with concurrent message_send/task_list probes. Ordinary-note traffic executes the mention parser through Communication.
    'ChecklistCoreTests.EvidenceAuthorityTests/testLargeReferenceImportBlocksOtherCommandsOnlyBriefly': QUALIFICATION_STORE_PATHS + _core_paths(
        'AcceptanceEvidence AgentReference AgentReviews AssistantGrants AttachmentOwnership '
        'Attachments AuthorizedFileReadAdapter BatchClaimContext Communication '
        'ConnectionRegistration DirectionContext EvidenceMeasures GroupKeys Groups '
        'HumanRequestFilePreparation ListFields ManagedAttachmentImport NativeCommunicationRoutes '
        'OrdinaryMentionCommands OrdinaryMentionTokens OrdinaryMentions Policy PolicySnapshots '
        'ProjectSettings ReferenceImportPreparation Relations RequiredEpic ReviewBatchInputs '
        'ReviewDrafts ReviewEvidence ReviewOutcomes ReviewRequirementIntegration ReviewRequirements '
        'ReviewReturns SafeFileRead ScopedMentionProjection ScopedTaskRecords SelectedTicketRead '
        'SourceExport SourceGitProcessAdapter StarterFields TaskContext TaskRecordSelection '
        'TaskReferenceValidation TaskSessions TaskStatusReason TicketChangeCoverage '
        'TicketPageFilters TicketPageRead TriageCommandEffects Work WorkAuthority WorkHealth '
        'WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/EvidenceAuthorityTests.swift',
        'Tests/ChecklistCoreTests/WriterLockTests.swift',
    ),
    # EvidenceAuthority base fixture + writer-lock extension; real source capture/submit or large reference attachment or captured-target review claim, with concurrent message_send/task_list probes. Ordinary-note traffic executes the mention parser through Communication.
    'ChecklistCoreTests.EvidenceAuthorityTests/testReviewClaimValidatesTheCapturedTargetBeforeTheWriter': QUALIFICATION_STORE_PATHS + _core_paths(
        'AcceptanceEvidence AgentReference AgentReviews AssistantGrants AttachmentOwnership '
        'Attachments AuthorizedFileReadAdapter BatchClaimContext Communication '
        'ConnectionRegistration DirectionContext EvidenceMeasures GroupKeys Groups '
        'HumanRequestFilePreparation ListFields ManagedAttachmentImport NativeCommunicationRoutes '
        'OrdinaryMentionCommands OrdinaryMentionTokens OrdinaryMentions Policy PolicySnapshots '
        'ProjectSettings ReferenceImportPreparation Relations RequiredEpic ReviewBatchInputs '
        'ReviewDrafts ReviewEvidence ReviewOutcomes ReviewRequirementIntegration ReviewRequirements '
        'ReviewReturns SafeFileRead ScopedMentionProjection ScopedTaskRecords SelectedTicketRead '
        'SourceExport SourceGitProcessAdapter StarterFields TaskContext TaskRecordSelection '
        'TaskReferenceValidation TaskSessions TaskStatusReason TicketChangeCoverage '
        'TicketPageFilters TicketPageRead TriageCommandEffects Work WorkAuthority WorkHealth '
        'WorkspacePageRead '
    ) + (
        'Tests/ChecklistCoreTests/EvidenceAuthorityTests.swift',
        'Tests/ChecklistCoreTests/WriterLockTests.swift',
    ),
    # Pure in-memory template -> StorageSnapshot.encoded -> compact Codable manifest and exact descriptor decoding. No CommandRouter or App/IPC fixture.
    'ChecklistCoreTests.StorageCompactManifestTests/testTwoHundredThousandObjectTemplateFitsManifestBudgetWithoutLosingDescriptors': _core_paths(
        'StorageCompactManifest StorageSnapshot StorageSnapshotAuthority '
    ) + (
        'Tests/ChecklistCoreTests/StorageCompactManifestTests.swift',
    ),
}
# Compatibility name for consumers of the original selector plan.
HEAVY_TESTS = QUALIFICATION_CASES
ISOLATED_TESTS = TIMING_TESTS + LOAD_SENSITIVE_TESTS
# macOS Seatbelt positive controls fail with SIGKILL when Git probes overlap.
# Keep native guards intact and isolate this class from all other test work.
ISOLATED_TEST_GROUPS = ('ChecklistCoreTests.SourceGitConfinementTests',
                        'ChecklistMCPServerTests.DelegateChildBindingTests')
# Explicit validation-only families; runtime inputs below take precedence.
# Other non-code files (including arbitrary Markdown and docs binary fixtures)
# have unknown impact and select the full unit suite; qualification uses its table.
VALIDATION_ONLY_FILES = ('README.md', 'AGENTS.md')
VALIDATION_ONLY_GLOBS = (
    'docs/*.md', 'docs/**/*.md', 'skills/**/*.md', 'templates/**/*.md',
    'plugins/**/*.md', 'Resources/AppIcon/README.md',
    'planning/**', 'plans/**', 'contracts/*.schema.json', 'contracts/README.md',
    'examples/*.json', 'docs/design/prompts.json',
)
# Repository files read at runtime, not represented by SwiftPM dependencies.
# RepositoryDependencyTests audits Swift and Python repository input reads.
FILE_TEST_CONSUMERS = {
    'Sources/ChecklistLegacyKeychain/ChecklistLegacyKeychain.c': ('ChecklistIPCTests',),
    'Sources/ChecklistLegacyKeychain/include/ChecklistLegacyKeychain.h': ('ChecklistIPCTests',),
    'docs/integrations.md': ('ChecklistCoreTests',),
    'examples/human-request.json': ('ChecklistCoreTests',),
    'contracts/human-request.schema.json': ('ChecklistCoreTests',),
    'contracts/ticket-bulk-edit.schema.json': ('ChecklistCoreTests',),
    'examples/media-intake.json': ('ChecklistCoreTests',),
    'examples/legacy-import-plan.json': ('ChecklistCoreTests',),
    'Tests/Fixtures/path-overlap-vectors.json': ('ChecklistIPCTests',),
}
# Keep Python readers separate from Swift target names; select both for shared inputs.
FILE_PYTHON_TEST_CONSUMERS = {
    'Tests/Fixtures/path-overlap-vectors.json': ('scripts/test_test_instances.py',),
}
# Source-inspection tests read these trees as text, independently of imports.
# GlossaryTests scans the Core test sources too.
SOURCE_TEST_CONSUMERS = {
    'Sources/ChecklistService/': ('ChecklistAppTests',),
    'Sources/ChecklistCLI/': ('ChecklistAppTests',),
    'Sources/ChecklistBridges/': ('ChecklistAppTests',),
    'Tests/ChecklistCoreTests/': ('ChecklistAppTests',),
}
BUILD_SCRIPTS = ('script/build_', 'script/build_and_run.sh', 'scripts/compile-component.sh',
                 'scripts/test_build_and_run.py')
PYTHON_TEST_OWNERS = {
    'scripts/validate-plan.py': [],  # Its own shape/reference checks run in VALIDATE.
    'script/verify_install.py': ['scripts/test_test_instances.py'],
    'scripts/public_source_privacy.py': ['scripts/test_prepare_public_source.py'],
}
# Executable target -> runtime test consumers (including copied/signed shims).
# The CLI is imported by ChecklistCLITests; MCP tests launch the input probe,
# not the shipping CLI. StorageCrashProbe is launched via CHECKLIST_STORAGE_PROBE.
# Build-version fixtures inspect bundle identity for the app and service names.
RUNTIME_TEST_CONSUMERS = {
    'ChecklistApp': ('ChecklistProvidersTests',),
    'ChecklistService': ('ChecklistProvidersTests',),
    'StorageCrashProbe': ('ChecklistCoreTests',),
    'ChecklistCLIInputProbe': ('ChecklistMCPServerTests',),
}
# Audited leaf entry points are narrower than their SwiftPM module.
# Declare actual target/group consumers, including source inspections and
# service callers. Unmapped source changes retain the module closure and
# are reported in the plan.
SOURCE_TEST_GROUPS = {
    'Sources/ChecklistCore/NativeOutcomeRecorder.swift': {
        'ChecklistCoreTests': ('NativeOutcomeRecorderTests',),
        'ChecklistAppTests': ('GlossaryTests',),
        # The sole production caller is the service entry point. Keep all its
        # native authority/scheduling groups, rather than infer no coverage.
        'ChecklistServiceTests': ('AuthorityTests', 'NativeCodeIdentityTests', 'ServiceRouteTimingTests',
                                  'ServiceQueueTimingTests', 'CallOverheadTests'),
    },
    'Sources/ChecklistApp/Views/TicketStatusReason.swift': {
        'ChecklistAppTests': (
            'TicketStatusReasonTests', 'TicketReadinessLabelTests', 'RemainingLazyListAccessibilityTests',
            'ScreenTimingTests', 'CachedProjectSwitchFrameTests', 'WorkspaceObservationTests',
            'LiveUpdateFreshnessTests', 'TriageBatchHistoryTests', 'TaskRowAccessibilityTests',
            'GlossaryTests', 'PlainLanguageTests', 'ViewStateTests', 'ConfirmationTests',
            'TicketPurgePreviewTests', 'NextActionTests'),
    },
    'Sources/ChecklistCore/MediaListConfiguration.swift': {
        # The only production caller is MediaListQueries; route tests enter
        # media_item_page/counts/approved_examples in MediaListQueryTests.
        'ChecklistCoreTests': ('MediaListConfigurationTests', 'MediaIntakeMappingTests', 'MediaListQueryTests'),
        'ChecklistAppTests': ('GlossaryTests',),
    },
    'Sources/ChecklistApp/Models/TicketPurgePreview.swift': {
        'ChecklistAppTests': ('TicketPurgePreviewTests', 'GlossaryTests', 'PlainLanguageTests', 'ViewStateTests'),
    },
    'Sources/ChecklistApp/Support/CodexComposeLink.swift': {
        'ChecklistAppTests': ('TaskHandoffTests', 'ProviderPresentationTests', 'GlossaryTests',
                              'PlainLanguageTests', 'ViewStateTests'),
    },
}

# These maps declare the complete test-consumer set, including dependent modules.
# Other source maps may narrow only one target and leave dependents conservative.
CLOSED_SOURCE_GROUPS = frozenset(SOURCE_TEST_GROUPS)


SOURCE_GROUP_SYMBOLS = {
    'Sources/ChecklistCore/NativeOutcomeRecorder.swift': (
        'NativeOutcomeRecorder', {
            'Sources/ChecklistCore/NativeOutcomeRecorder.swift',
            'Sources/ChecklistService/main.swift',
        }),
    'Sources/ChecklistApp/Views/TicketStatusReason.swift': (
        'TicketStatusReason(?:Presentation|Line|Detail)', {
            'Sources/ChecklistApp/Models/TaskRowPresentation.swift',
            'Sources/ChecklistApp/Views/EpicDetailView.swift',
            'Sources/ChecklistApp/Views/TaskDetailView.swift',
            'Sources/ChecklistApp/Views/TaskWorkspaceView.swift',
            'Sources/ChecklistApp/Views/TicketStatusReason.swift',
            'Sources/ChecklistApp/Views/TriageDetailView.swift',
        }),
    'Sources/ChecklistCore/MediaListConfiguration.swift': (
        '(?:MediaListConfiguration|MediaListItem|MediaListEntry|MediaHistoricalExamples|MediaHistoricalExampleRequest|MediaMaterialReference)', {
            'Sources/ChecklistCore/MediaListConfiguration.swift',
            'Sources/ChecklistCore/MediaListQueries.swift',
        }),
    'Sources/ChecklistApp/Models/TicketPurgePreview.swift': (
        'TicketPurgePreview', {
            'Sources/ChecklistApp/Models/TicketPurgePreview.swift',
        }),
    'Sources/ChecklistApp/Support/CodexComposeLink.swift': (
        'CodexComposeLink', {
            'Sources/ChecklistApp/Support/CodexComposeLink.swift',
        }),
}


def source_test_groups(root, path):
    mapping = SOURCE_TEST_GROUPS.get(path, {})
    if path in SOURCE_GROUP_SYMBOLS:
        symbol, expected = SOURCE_GROUP_SYMBOLS[path]
        readers = {source.relative_to(root).as_posix() for source in (root / 'Sources').rglob('*.swift')
                   if re.search(r'\b' + symbol + r'\b', source.read_text())}
        if readers != expected:
            return {}  # A new/deleted caller invalidates the narrower map.
    return mapping


def test_file_groups(root, target, path):
    """Narrow independent test-only files; shared fixture/extension edits stay whole-target."""
    source = root / path
    if not source.is_file() or source.suffix != '.swift':
        return None
    text = source.read_text()
    classes = re.findall(r'final class (\w+)\s*:\s*XCTestCase', text)
    methods = re.findall(r'func (\w+)\s*\(', text)
    if (not classes or not methods or any(not name.startswith('test') for name in methods)
            or re.search(r'^(?:(?:private|fileprivate|internal|public) )?(?:let|var|func|struct|enum|class|extension)\b', text, re.M)):
        return None
    # A class used by another fixture, extension or subclass is shared state.
    for sibling in (root / target['path']).rglob('*.swift'):
        if sibling != source and any(re.search(r'\b' + re.escape(name) + r'\b', sibling.read_text()) for name in classes):
            return None
    return tuple(classes)


# One interpreter for round checks, background full suites and validation.
SCRIPT_PYTHON = ['uv', 'run', '--no-project', '--python', '3.12',
                 '--with', 'jsonschema', '--with', 'pyyaml', 'python']
VALIDATE = SCRIPT_PYTHON + ['scripts/validate-plan.py']


def package_graph(root, scratch):
    """Cache only the graph (not the changed paths), keyed by manifest bytes."""
    digest = hashlib.sha256((root / 'Package.swift').read_bytes()).hexdigest()
    cache = scratch / 'affected-tests' / (digest + '.json')
    if cache.exists():
        try:
            return json.loads(cache.read_text())
        except (ValueError, OSError):
            pass
    result = subprocess.run(['swift', 'package', '--scratch-path', str(scratch),
                             'describe', '--type', 'json'], cwd=root, check=True,
                            text=True, capture_output=True)
    graph = json.loads(result.stdout)
    cache.parent.mkdir(parents=True, exist_ok=True)
    # Separate processes may plan checks in the same slot; publish atomically.
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', dir=cache.parent, delete=False) as output:
        output.write(json.dumps(graph))
        temporary = Path(output.name)
    temporary.replace(cache)
    return graph


def changed_paths(root, base):
    # Include both rename endpoints, deleted paths, staged/unstaged and untracked files.
    tracked = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only', '-z', base, '--'], cwd=root)
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=root)
    return sorted(set(p.decode() for p in (tracked + untracked).split(b'\0') if p))


def python_tests(root, path):
    if path in PYTHON_TEST_OWNERS:
        return PYTHON_TEST_OWNERS[path]
    name = PurePosixPath(path).name
    if path.startswith('scripts/') and name.startswith('test_'):
        return [path]
    candidate = 'scripts/test_' + PurePosixPath(path).stem.replace('-', '_') + '.py'
    return [candidate] if (root / candidate).is_file() else None


def is_target_resource(root, target, path):
    """SwiftPM describes processed/copied resources separately from sources."""
    for resource in target.get('resources', []):
        resource_path = Path(resource['path'])
        if resource_path.is_absolute():
            try:
                resource_path = resource_path.relative_to(root)
            except ValueError:
                continue
        for candidate in (resource_path.as_posix(), target['path'] + '/' + resource_path.as_posix()):
            if path == candidate or path.startswith(candidate + '/'):
                return True
    return False


CLOCK_READ = re.compile(r'systemUptime|ContinuousClock\.now|SuspendingClock\.now|DispatchTime\.now|CFAbsoluteTimeGetCurrent|timeIntervalSince\(|Date\(\)\s*-')
TIME_NAME = re.compile(r'(?i)(elapsed|seconds|millis|(?<![a-z])ms(?![a-z])|wait|duration)')

def _close(text, start, opening, closing):
    depth = 0
    for index in range(start, len(text)):
        if text[index] == opening:
            depth += 1
        elif text[index] == closing:
            depth -= 1
            if depth == 0:
                return index
    return len(text)

def _arguments(text, start):
    end = _close(text, start, '(', ')')
    args, depth, current = [], 0, ''
    for char in text[start + 1:end]:
        depth += char in '([{'
        depth -= char in ')]}'
        if char == ',' and depth == 0:
            args.append(current.strip()); current = ''
        else:
            current += char
    return args + [current.strip()]

def _functions(text):
    """Yield (name, start, end, type) for members of top-level types (brace depth 1)."""
    depth, depths = 0, []
    for char in text:
        depths.append(depth)
        depth += (char == '{') - (char == '}')
    types = []
    for match in re.finditer(r'\b(?:class|struct|enum|actor|extension)\s+(\w+)[^{;]*\{', text):
        if depths[match.start()] == 0:
            types.append((match.group(1), match.end() - 1, _close(text, match.end() - 1, '{', '}')))
    for match in re.finditer(r'\bfunc\s+(\w+)\s*(?:<[^>]*>)?\(', text):
        if depths[match.start()] != 1:
            continue
        body = text.find('{', _close(text, match.end() - 1, '(', ')'))
        owner = next((name for name, start, end in types if start < match.start() < end), None)
        if body >= 0 and owner:
            yield match.group(1), match.start(), _close(text, body, '{', '}'), owner


def _budget(body):
    # Conservative source audit, not a Swift interpreter. Follow simple local
    # assignments and sample arrays, then inspect both comparison assertion forms.
    # Keep clock/configuration equality tests and injected clocks in the unit suite.
    clock = re.compile(CLOCK_READ.pattern + r'|timeIntervalSinceNow|Duration\b')
    timed = set()
    expressions = re.findall(r'\b(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*([^;,\n]+)', body)
    expressions += re.findall(r'\b(\w+)\.append\(([^\n]+)', body)

    def is_time(expression):
        return bool(clock.search(expression) or TIME_NAME.search(expression) or
                    any(re.search(r'\b' + re.escape(name) + r'\b', expression) for name in timed))

    for _ in range(len(expressions) + 1):
        previous = set(timed)
        timed.update(name for name, value in expressions
                     if clock.search(value) or any(re.search(r'\b' + re.escape(other) + r'\b', value)
                                                   for other in timed))
        if previous == timed:
            break
    for match in re.finditer(r'XCTAssert(LessThan(?:OrEqual)?|True)\s*\(', body):
        args = _arguments(body, match.end() - 1)
        if match.group(1) == 'True':
            if not args:
                continue
            measured = args[0]
            # Arrays put the measured variable outside the closure's comparison.
            if not re.search(r'<(?:=)?', measured):
                reverse = re.search(r'>=?\s*(.+)', measured)
                if not reverse or not is_time(reverse.group(1)):
                    continue
        else:
            if len(args) < 2:
                continue
            measured = args[0]
        if is_time(measured):
            yield body[:match.start()].count('\n'), ' | '.join(args[:2])

def wall_clock_budget_cases(root):
    """Map XCTest IDs to wall-clock budget assertions of any size, including via same-file helpers."""
    cases = {}
    for source in sorted((root / 'Tests').rglob('*.swift')):
        text = source.read_text()
        target = source.relative_to(root / 'Tests').parts[0]
        functions = list(_functions(text))
        direct = {name: list(_budget(text[start:end])) for name, start, end, _ in functions}
        timed = {name for name, hits in direct.items() if hits}
        changed = True
        while changed:
            changed = False
            for name, start, end, _ in functions:
                if name not in timed and any(re.search(r'\b' + helper + r'\s*\(', text[start:end]) for helper in timed if helper != name):
                    timed.add(name); changed = True
        for name, start, end, owner in functions:
            if name.startswith('test') and name in timed:
                gated = 'QualificationSuite.requireEnabled' in text[start:end]
                cases[target + '.' + owner + '/' + name] = (str(source.relative_to(root)), gated)
    return cases


def qualification_reasons(paths):
    """Keep the changed input for every selected case, including deleted fixtures."""
    return {case: [path for path in paths if any(fnmatchcase(path, pattern) for pattern in patterns)]
            for case, patterns in QUALIFICATION_SOURCE_PATHS.items()}



def select(root, graph, paths, scratch, full=False, qualification=False, last_round=False):
    targets = {target['name']: target for target in graph['targets']}
    all_tests = {name for name, target in targets.items() if target['type'] == 'test'}
    affected, python, unknown = set(), set(), []
    # Longest target path wins (e.g. StorageCrashProbe/ReleasedCore).
    owners = sorted(targets.values(), key=lambda target: len(target['path']), reverse=True)
    normalized = sorted(set(PurePosixPath(path.removeprefix('./')).as_posix() for path in paths))
    for path in normalized:
        parts = PurePosixPath(path).parts
        if PurePosixPath(path).is_absolute() or '..' in parts:
            unknown.append(path)
        elif path == 'Package.swift' or path == 'Package.resolved' or path.startswith(BUILD_SCRIPTS):
            unknown.append(path)
        elif path in FILE_TEST_CONSUMERS or path in FILE_PYTHON_TEST_CONSUMERS:
            consumers = FILE_TEST_CONSUMERS.get(path, ())
            python_consumers = FILE_PYTHON_TEST_CONSUMERS.get(path, ())
            if any(name not in all_tests for name in consumers) or any(
                    not (root / name).is_file() for name in python_consumers):
                unknown.append(path)
            affected.update(name for name in consumers if name in all_tests)
            python.update(name for name in python_consumers if (root / name).is_file())
            # Explicit readers supplement the package graph, including resources.
            owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
            if owner and (PurePosixPath(path).suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp', '.s')
                          or is_target_resource(root, owner, path)):
                affected.add(owner['name'])
        elif path.startswith(('Sources/', 'Tests/')) or any(
                path.startswith(target['path'] + '/') for target in owners):
            owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
            if owner and (PurePosixPath(path).suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp', '.s')
                          or is_target_resource(root, owner, path)):
                affected.add(owner['name'])
                for prefix, consumers in SOURCE_TEST_CONSUMERS.items():
                    if path.startswith(prefix):
                        affected.update(name for name in consumers if name in targets)
            else:
                unknown.append(path)
        elif path.endswith('.py') and path.startswith(('script/', 'scripts/')):
            own_tests = python_tests(root, path)
            if own_tests is not None:
                python.update(own_tests)
            else:
                unknown.append(path)
        elif path in VALIDATION_ONLY_FILES or any(
                fnmatchcase(path, pattern) for pattern in VALIDATION_ONLY_GLOBS):
            pass
        else:
            unknown.append(path)
    def dependency_closure(initial):
        result = set(initial)
        while True:
            dependents = {name for name, target in targets.items()
                          if result.intersection(target.get('target_dependencies', []))}
            for producer, consumers in RUNTIME_TEST_CONSUMERS.items():
                if producer in result:
                    dependents.update(name for name in consumers if name in targets)
            added = dependents - result
            if not added:
                return result
            result.update(added)

    affected = dependency_closure(affected)
    path_consumers = {}
    for path in normalized:
        owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
        seeds = set(FILE_TEST_CONSUMERS.get(path, ()))
        if owner:
            seeds.add(owner['name'])
        for prefix, consumers in SOURCE_TEST_CONSUMERS.items():
            if path.startswith(prefix):
                seeds.update(consumers)
        path_consumers[path] = dependency_closure(seeds)
    if unknown or full:
        affected.update(targets)
        python.update(str(path.relative_to(root)) for path in (root / 'scripts').glob('test_*.py'))
    tests = sorted(all_tests.intersection(affected))
    explicitly_qualified = qualification or last_round
    qualification_mode = ('requested-full' if qualification else 'pass-final-round' if last_round
                          else 'full-default' if full else 'affected')
    reasons = qualification_reasons(normalized)
    qualification_tests = (list(QUALIFICATION_CASES) if explicitly_qualified else
                           [] if full else [case for case in QUALIFICATION_CASES if reasons[case]])
    qualification = bool(qualification_tests)
    source_groups = {path: source_test_groups(root, path) for path in normalized}
    group_fallback_paths = []
    groups = {}
    if not full and not unknown:
        for path in normalized:
            owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
            if owner and owner['type'] != 'test' and not source_groups[path]:
                group_fallback_paths.append(path)
        for name in tests:
            relevant = []
            for path in normalized:
                if name not in path_consumers[path]:
                    continue
                mapping = source_groups[path]
                owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
                if name in mapping:
                    relevant.append(mapping[name])
                elif mapping and path in CLOSED_SOURCE_GROUPS:
                    relevant.append(())  # Declared closed map: no consumer in this target.
                elif name in FILE_TEST_CONSUMERS.get(path, ()):
                    relevant.append(None)
                elif owner and owner['name'] == name:
                    relevant.append(test_file_groups(root, owner, path))
                elif owner and owner['type'] != 'test':
                    relevant.append(None)
            if relevant and all(selected is not None for selected in relevant):
                groups[name] = sorted({group for selected in relevant for group in selected})
        tests = [name for name in tests if name not in groups or groups[name]]
        groups = {name: selected for name, selected in groups.items() if name in tests}
    # Qualification is independent of unit group narrowing: an explicitly requested
    # full qualification includes Core/App/IPC cases even for a docs-only change.
    skip = [case for case in QUALIFICATION_CASES if case not in qualification_tests] if tests else []
    swift = []
    isolated = []
    qualification_commands = []
    timing_tests, timing_commands, timing_deferred = [], [], False
    if tests or full or qualification_tests:
        command = ['swift', 'test', '--parallel', '--num-workers', '10', '--cache-path',
                   str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                   '--enable-dependency-cache', '--scratch-path', str(scratch)]
        if not full:
            for target in tests:
                suffix = '(?:' + '|'.join(re.escape(group) for group in groups[target]) + r')(?:/|$)' if target in groups else ''
                command.extend(['--filter', '^' + re.escape(target) + r'\.' + suffix])
        for case in QUALIFICATION_CASES + ISOLATED_TESTS:
            command.extend(['--skip', '^' + re.escape(case) + r'(?:/|$)'])
        if 'ChecklistCoreTests' in tests or any(case.startswith('ChecklistCoreTests.') for case in qualification_tests):
            command = ['env', 'CHECKLIST_STORAGE_PROBE=' + str(scratch / 'out/Products/Debug/StorageCrashProbe')] + command
        command = ['env', 'CHECKLIST_TEST_TEMPLATE_ROOT=' + str(scratch / 'test-store-templates'), 'CHECKLIST_QUALIFICATION=0'] + command
        isolated = [group for group in ISOLATED_TEST_GROUPS
                    if group.split('.')[0] in tests and (group.split('.')[0] not in groups
                    or group.split('.')[1] in groups[group.split('.')[0]])]
        for group in isolated:
            command.extend(['--skip', '^' + re.escape(group) + r'(?:/|$)'])
        if tests or full:
            swift.append(command)
        for target in sorted({group.split('.')[0] for group in isolated}):
            # The parallel pass above builds this exact test bundle. Selecting
            # the native class directly avoids rediscovering/starting every
            # unrelated bundle, while all its methods remain in one serial host.
            single = command[:command.index('swift')]
            single.extend(['xcrun', 'xctest', '-XCTest', ','.join(group for group in isolated if group.startswith(target + '.')),
                           str(scratch / 'debug' / (target + '.xctest'))])
            swift.append(single)
        timing_tests = [case for case in ISOLATED_TESTS if case.split('.')[0] in tests and (
            case.split('.')[0] not in groups or case.split('.')[1].split('/')[0] in groups[case.split('.')[0]])]
        # Wall-clock budgets are performance checks (CL-266 item 2): they run in
        # full qualification runs (--qualification/--last-round) or when a
        # timing test file itself changes; ordinary affected runs defer them.
        timing_classes = {case.split('.')[1].split('/')[0] for case in timing_tests}
        timing_changed = any(path.startswith('Tests/') and Path(path).stem in timing_classes for path in normalized)
        timing_deferred = bool(timing_tests) and not (explicitly_qualified or timing_changed)
        if timing_tests and not timing_deferred:
            # Same environment and process-per-test isolation as the parallel
            # pass, but one worker: each budget is measured with no sibling test.
            timed = command[:command.index('swift') + 2]
            timed.extend(['--parallel', '--num-workers', '1', '--cache-path',
                          str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                          '--enable-dependency-cache', '--scratch-path', str(scratch)])
            for case in timing_tests:
                timed.extend(['--filter', '^' + re.escape(case) + '$'])
            timing_commands.append(timed)
            swift.append(timed)
        if qualification_tests:
            qualified = command[:command.index('swift') + 2]
            qualified = ['CHECKLIST_QUALIFICATION=1' if arg == 'CHECKLIST_QUALIFICATION=0' else arg for arg in qualified]
            qualified.extend(['--parallel', '--num-workers', '1', '--cache-path',
                              str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                              '--enable-dependency-cache', '--scratch-path', str(scratch)])
            for case in qualification_tests:
                qualified.extend(['--filter', '^' + re.escape(case) + '$'])
            qualification_commands.append(qualified)
            swift.append(qualified)
    # uv supplies the dependencies needed by the exporter/validator tests too.
    python_commands = [SCRIPT_PYTHON + [path] for path in sorted(python)]
    return {'paths': normalized, 'affected_targets': sorted(affected), 'test_targets': tests,
            'python_tests': sorted(python), 'fallback_paths': unknown, 'skip': skip, 'full': full, 'qualification': qualification,
            'isolated_test_groups': isolated, 'test_groups': groups,
            'group_fallback_paths': group_fallback_paths, 'qualification_mode': qualification_mode,
            'qualification_reasons': {case: reasons[case] for case in qualification_tests},
            'default_swift_commands': [command for command in swift if command not in qualification_commands and command not in timing_commands],
            'qualification_commands': qualification_commands, 'qualification_tests': qualification_tests,
            'qualification_test_targets': sorted({case.split('.')[0] for case in qualification_tests}),
            'timing_commands': timing_commands, 'timing_tests': timing_tests, 'timing_deferred': timing_deferred,
            'swift_commands': swift, 'commands': swift + python_commands + [VALIDATE]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument('--base', help='diff commit against the working tree, including untracked files')
    source.add_argument('--paths', nargs='+', help='repository-relative changed paths')
    source.add_argument('--paths-file', type=Path, help='newline-delimited paths, or - for stdin')
    parser.add_argument('--full', action='store_true', help='full default Swift suite in parallel and all Python tests')
    parser.add_argument('--qualification', action='store_true', help='include the opt-in scale, timing and soak qualification suite')
    parser.add_argument('--last-round', action='store_true', help='full qualification once, on the final round of a pass')
    parser.add_argument('--json', action='store_true', help='emit the plan as JSON argv arrays')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--scratch-path', type=Path, default=Path('.build'))
    args = parser.parse_args(argv)
    if not any((args.base, args.paths, args.paths_file, args.full, args.qualification, args.last_round)):
        parser.error('supply --base, --paths, --paths-file, --full, --qualification or --last-round')
    root = args.root.resolve()
    scratch = args.scratch_path.resolve()
    try:
        paths = args.paths or []
        if args.base:
            paths = changed_paths(root, args.base)
        elif args.paths_file:
            contents = sys.stdin.read() if str(args.paths_file) == '-' else args.paths_file.read_text()
            paths = contents.splitlines()
        plan = select(root, package_graph(root, scratch), paths, scratch, args.full, args.qualification, args.last_round)
        if args.json:
            print(json.dumps(plan, indent=2))
        else:
            print('Unit test targets: ' + (', '.join(plan['test_targets']) or '(none)'))
            print('Qualification mode: ' + plan['qualification_mode'])
            print('Qualification targets: ' + (', '.join(plan['qualification_test_targets']) or '(none)'))
            for case, paths in plan['qualification_reasons'].items():
                print('Qualification case: ' + case + ' <- ' + (', '.join(paths) or plan['qualification_mode']))
            if plan['group_fallback_paths']:
                print('Module group fallback for: ' + ', '.join(plan['group_fallback_paths']))
            if plan['fallback_paths']:
                print('Full selection for: ' + ', '.join(plan['fallback_paths']))
            for target, groups in plan['test_groups'].items():
                print('Test groups: ' + target + ': ' + ', '.join(groups))
            if plan['timing_commands']:
                print('Timing group: separate single-worker invocation')
            elif plan['timing_deferred']:
                print('Timing group: deferred to qualification runs (--qualification)')
            if plan['qualification_commands']:
                print('Qualification suite: separate single-worker invocation')
            if plan['skip']:
                print('Heavy cases skipped: ' + ', '.join(plan['skip']))
            for command in plan['commands']:
                print(shlex.join(command))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'affected_tests: {error}\n')


if __name__ == '__main__':
    main()
