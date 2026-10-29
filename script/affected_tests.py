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
    'ChecklistCoreTests.MediaWorkflowQualificationTests/test300ItemRoundGroupingFilterUpdateAndListBudgets',
    'ChecklistCoreTests.MediaWorkflowQualificationTests/test1000ItemRoundGroupingFilterUpdateAndListBudgets',
    'ChecklistCoreTests.MediaWorkflowQualificationTests/test1200ItemRoundAboveTheFormerCeilingKeepsListBudgets',
    'ChecklistCoreTests.MediaWorkflowQualificationTests/testBulkPartialSuccessLostReplyReversalsReworkAndExamplesAboveOneThousandItems',
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
    'ChecklistServiceTests.BootstrapAdmissionTests/testFreshBootstrapReadsAndTwoQueuedWritesFinishWhileActualWriterIsHeld',
    'ChecklistAppTests.ApplicationTerminationTests/testOpenFloatingCaptureQuitsAndRestoresBlankTextAndFiles',
    'ChecklistAppTests.CachedScreenReturnTests/testTemplateCatalogOverviewReturnNeedsNoReadOrCatalogReplay',
    'ChecklistAppTests.MediaPlaybackComparisonTests/testNonloopingTakeRetainsCompletedItemAndReplaysWithoutUndoingPauseOrUnload',
    'ChecklistAppTests.MediaPlaybackComparisonTests/testSyntheticWrittenMovieIsSelfContainedAndProbeMeasuresIt',
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
    'ChecklistCoreTests.MediaListScaleTests/testThousandItemPublishedRoundListIsFast',
    'ChecklistCoreTests.MediaListScaleTests/testFiveThousandItemPublishedRoundListIsFast',
    'ChecklistCoreTests.MediaPreparationScaleTests/testLargeProjectPreparationReadsTouchedRecordsAndHoldsAtomicityReplayAndFencing',
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
# Compatibility name for consumers of the original selector plan.
HEAVY_TESTS = QUALIFICATION_CASES
ISOLATED_TESTS = TIMING_TESTS + LOAD_SENSITIVE_TESTS
# macOS Seatbelt positive controls fail with SIGKILL when Git probes overlap.
# Keep native guards intact and isolate this class from all other test work.
ISOLATED_TEST_GROUPS = ('ChecklistCoreTests.SourceGitConfinementTests',
                        'ChecklistMCPServerTests.DelegateChildBindingTests')
# Explicit validation-only families; runtime inputs below take precedence.
# Other non-code files (including arbitrary Markdown and docs binary fixtures)
# have unknown impact and select the full unit suite; qualification uses measured coverage or module fallback.
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
    'script/index_store.py': ['scripts/test_test_impact_map.py', 'scripts/test_shared_test_impact.py'],
    'script/test_impact_map.py': ['scripts/test_test_impact_map.py', 'scripts/test_shared_test_impact.py'],
    'script/shared_test_impact.py': ['scripts/test_shared_test_impact.py', 'scripts/test_affected_tests.py'],
    'scripts/public_source_privacy.py': ['scripts/test_prepare_public_source.py'],
    'scripts/public-source-files.json': ['scripts/test_prepare_public_source.py'],
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


CODE_SUFFIXES = ('.swift', '.c', '.h', '.m', '.mm', '.cpp', '.s')
TOP_LEVEL_DECLARATION = re.compile(
    r'^(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(private|fileprivate|internal|public|open)\s+)?(?:(?:final|static|indirect)\s+)*'
    r'(class|struct|enum|actor|protocol|extension|func|let|var|typealias)\s+(\w+)([^\n{]*)', re.M)


def unrecognized_top_level(text):
    """Column-0 lines that are not imports, attributes, directives or recognized declarations."""
    return [line.strip() for line in text.splitlines() if re.match(r'[A-Za-z]', line)
            and not re.match(r'import\b', line) and not TOP_LEVEL_DECLARATION.match(line)]


def direct_test_input(path):
    """Changed inputs whose readers the planner selects directly (CL-299).

    Test-tree code and runtime inputs with named readers keep a valid map; every
    other changed file keeps the measured edges recorded for it.
    """
    suffix = PurePosixPath(path).suffix
    if path.startswith('Tests/') and suffix in CODE_SUFFIXES:
        return True
    return (path in FILE_TEST_CONSUMERS or path in FILE_PYTHON_TEST_CONSUMERS) and suffix not in CODE_SUFFIXES


def declared_test_classes(root, target, cache):
    if target['name'] not in cache:
        names = set()
        for source in (root / target['path']).rglob('*.swift'):
            names.update(re.findall(r'\bclass\s+(\w+)', source.read_text(errors='replace')))
        cache[target['name']] = names
    return cache[target['name']]


def test_file_declarations(text, known):
    """Own XCTestCase classes and other non-private top-level declarations."""
    own, shared = set(), ['unrecognized ' + line[:40] for line in unrecognized_top_level(text)]
    for access, kind, name, rest in TOP_LEVEL_DECLARATION.findall(text):
        if kind == 'class' and re.search(r'\bXCTestCase\b', rest):
            own.add(name)
        elif kind == 'extension' and name in known:
            own.add(name)
        elif access not in ('private', 'fileprivate'):
            shared.append(kind + ' ' + name)
    return own, shared


def test_file_selection(root, targets, owner, path, impact_map, cache):
    """Select a changed test file's own classes/cases plus its measured consumers.

    Returns {'fallback': reason} when the consumers cannot be determined.
    """
    entry = impact_map.get('sources', {}).get(path)
    classes, cases, broad = {}, set(), set()

    def add(group):
        name, _, cls = group.partition('.')
        target = targets.get(name)
        # A deleted or renamed class has no remaining declaration to run.
        if target and target['type'] == 'test' and cls in declared_test_classes(root, target, cache):
            classes.setdefault(name, set()).add(cls)

    if entry is not None:
        for group in entry['classes']:
            add(group)
        cases.update(case for case in entry['qualification_cases'] if case in QUALIFICATION_CASES)
    source = root / path
    if not source.is_file():
        if entry is None:
            return {'fallback': 'deleted test file is not in the coverage map; its consumers are unknown'}
        return {'reason': 'deleted test file: its measured consumers that still exist',
                'classes': classes, 'cases': cases, 'broad': broad}
    text = source.read_text(errors='replace')
    known = {group.split('.', 1)[1] for group in impact_map.get('class_inventory', []) +
             impact_map.get('measured_classes', []) if group.startswith(owner['name'] + '.')}
    own, shared = test_file_declarations(text, known)
    if entry is None:
        if not own:
            return {'fallback': 'new test file declares no XCTestCase class'}
        if shared:
            return {'fallback': 'new test file declares shared test helpers (' + ', '.join(shared[:5]) +
                                '); their consumers are not measured'}
        users = sorted(other.relative_to(root).as_posix() for other in (root / owner['path']).rglob('*.swift')
                       if other != source and any(re.search(r'\b' + re.escape(name) + r'\b', other.read_text(errors='replace'))
                                                  for name in own - known))
        if users:
            return {'fallback': 'new test file classes are used by ' + ', '.join(users[:5]) +
                                '; their consumers are not measured'}
        reason = 'new test file: its own classes and qualification cases'
        for prefix, readers in SOURCE_TEST_CONSUMERS.items():
            if not path.startswith(prefix):
                continue
            for reader in readers:
                if reader not in targets:
                    continue
                # Source-inspection classes read the whole directory as text.
                found = [group for group, references in impact_map.get('inspection_references', {}).items()
                         if group.startswith(reader + '.') and any(item.startswith(prefix) for item in references)]
                for group in found:
                    add(group)
                if not found:
                    # Inspection readers are unit classes; qualification edges are executed coverage.
                    broad.add(reader)
            reason += ' plus source-inspection readers of ' + prefix
    else:
        reason = 'changed test file: its own classes and qualification cases plus measured consumers'
    for name in own:
        classes.setdefault(owner['name'], set()).add(name)
    for case in QUALIFICATION_CASES:
        group, _, method = case.partition('/')
        target_name, _, cls = group.partition('.')
        if (target_name == owner['name'] and cls in own and
                re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(', text)):
            cases.add(case)
    return {'reason': reason, 'classes': classes, 'cases': cases, 'broad': broad}


# Value conformances add operations that unchanged code could not name before;
# CustomStringConvertible and similar protocols change existing output and fall back.
VALUE_CONFORMANCES = ('Equatable', 'Hashable', 'Sendable')
RUNTIME_LOOKUP = re.compile(r'@(?:main|objc|_cdecl|_dynamicReplacement|NSApplicationMain)\b|NSClassFromString|override\b')


def new_source_names(text):
    """Names a new Swift source adds, or (None, reason) when unchanged code could observe it.

    New top-level declarations are reachable only by code that names them. An
    extension of an existing type may add members, and conform only to protocols
    the same file declares; overrides, runtime lookups and entry points fall back.
    """
    if RUNTIME_LOOKUP.search(text):
        return None, 'new source uses an override, entry point or runtime lookup'
    unrecognized = unrecognized_top_level(text)
    if unrecognized:
        return None, 'new source has an unrecognized top-level declaration: ' + unrecognized[0][:60]
    declarations = list(TOP_LEVEL_DECLARATION.finditer(text))
    declared = {match.group(3) for match in declarations if match.group(2) != 'extension'}
    names = set()
    for match in declarations:
        access, kind, name, rest = match.groups()
        if access in ('private', 'fileprivate'):
            continue
        if kind != 'extension':
            names.add(name)
            continue
        if name in declared:
            continue
        conformances = [part.replace('@unchecked', '').strip() for part in
                        re.sub(r'\bwhere\b.*', '', rest).partition(':')[2].split(',')]
        if any(item and item not in declared and item not in VALUE_CONFORMANCES for item in conformances):
            return None, 'new source adds a conformance to existing type ' + name
        # The value-conformance requirements themselves (==, hash(into:)).
        requirements = ('', 'hash') if set(conformances) & set(VALUE_CONFORMANCES) else ()
        brace = text.find('{', match.end() - 1)
        end = _close(text, brace, '{', '}')
        depth, body = 0, text[brace + 1:end]
        for line in body.splitlines():
            if depth == 0:
                member = re.match(r'\s*(?:@\w+(?:\([^)]*\))?\s+)*((?:\w+\s+)*)(func|var|let|case|subscript|init|struct|class|enum|actor|typealias)\b\s*(\w*)', line)
                if member and not re.search(r'\b(?:private|fileprivate)\b', member.group(1)):
                    if member.group(2) == 'func' and member.group(3) in requirements:
                        pass
                    elif member.group(2) in ('init', 'subscript') or not member.group(3):
                        return None, 'new source adds an initializer, operator or subscript to existing type ' + name
                    else:
                        names.add(member.group(3))
            depth += line.count('{') - line.count('}')
    if not names:
        return None, 'new source declares no new names'
    return names, None


def new_source_reachability(root, normalized, candidates):
    """Map each self-contained new source to changed files that name it.

    Unchanged code compiled without these names, so it cannot reach them; only
    changed files can. A new source is covered when a referencing chain reaches a
    changed file with its own selection. Returns (reached, reasons).
    """
    names, reasons = {}, {}
    for path in candidates:
        found, reason = new_source_names((root / path).read_text(errors='replace'))
        if found is None:
            reasons[path] = reason
        else:
            names[path] = found
    if names:
        changed = set(normalized)
        pattern = re.compile(r'\b(?:' + '|'.join(sorted(map(re.escape, set().union(*names.values())))) + r')\b')
        existing = set()
        for folder in ('Sources', 'Tests', 'Packages'):
            for source in (root / folder).rglob('*.swift'):
                if source.relative_to(root).as_posix() not in changed:
                    existing.update(pattern.findall(source.read_text(errors='replace')))
        for path in sorted(names):
            if names[path] & existing:
                reasons[path] = ('new source reuses names in unchanged files: ' +
                                 ', '.join(sorted(names[path] & existing)[:5]))
                del names[path]
    texts = {path: (root / path).read_text(errors='replace') for path in normalized
             if path.endswith('.swift') and (root / path).is_file()}
    referenced_by = {path: sorted(other for other, text in texts.items() if other != path and re.search(
        r'\b(?:' + '|'.join(map(re.escape, sorted(found))) + r')\b', text)) for path, found in names.items()}
    covered = set()
    while True:
        added = {path for path, users in referenced_by.items() if path not in covered and
                 any(user not in referenced_by or user in covered for user in users)}
        if not added:
            break
        covered |= added
    for path in sorted(set(names) - covered):
        reasons[path] = 'new source is not reached from a changed file with its own selection'
    return {path: referenced_by[path] for path in sorted(covered)}, reasons


def runtime_input_selection(root, targets, path, impact_map, cache):
    """A named runtime input selects the classes of the test files that name it."""
    classes, cases, broad, readers = {}, set(), set(), []
    name = PurePosixPath(path).name
    for consumer in FILE_TEST_CONSUMERS.get(path, ()):
        target = targets.get(consumer)
        if not target:
            continue
        files = sorted(source.relative_to(root).as_posix() for source in (root / target['path']).rglob('*.swift')
                       if name in source.read_text(errors='replace'))
        selections = [test_file_selection(root, targets, target, item, impact_map, cache) for item in files]
        if not files or any('fallback' in selection for selection in selections):
            # A dynamic read may come from any class or qualification case.
            broad.add(consumer)
            cases.update(case for case in QUALIFICATION_CASES if case.split('.')[0] == consumer)
            continue
        readers.extend(files)
        for selection in selections:
            for group, values in selection['classes'].items():
                classes.setdefault(group, set()).update(values)
            cases.update(selection['cases'])
            broad.update(selection['broad'])
    reason = ('runtime input: classes and qualification cases of its reading test files ' + ', '.join(readers)
              if readers else 'runtime input')
    if broad:
        reason += '; whole target where no literal reader is measured: ' + ', '.join(sorted(broad))
    return {'reason': reason, 'classes': classes, 'cases': cases, 'broad': broad}


# One interpreter for round checks, background full suites and validation.
SCRIPT_PYTHON = ['uv', 'run', '--no-project', '--python', '3.12',
                 '--with', 'jsonschema', '--with', 'pyyaml', 'python']
VALIDATE = SCRIPT_PYTHON + ['scripts/validate-plan.py']


def package_graph(root, scratch):
    """Cache only the graph (not the changed paths), keyed by manifest bytes."""
    manifests = {root / 'Package.swift', root / 'Package.resolved'}
    manifests.update((root / 'Packages').rglob('Package.swift'))
    manifests.update((root / 'Packages').rglob('Package.resolved'))
    fingerprint = hashlib.sha256(b'shared-package-graph-v1\0')
    for manifest in sorted(manifests):
        fingerprint.update(str(manifest.relative_to(root)).encode() + b'\0')
        fingerprint.update(manifest.read_bytes() if manifest.is_file() else b'<absent>')
    digest = fingerprint.hexdigest()
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
    shared = root / 'Packages/ChecklistShared'
    if (shared / 'Package.swift').is_file():
        package_path = shared.relative_to(root).as_posix()
        result = subprocess.run(['swift', 'package', '--package-path', str(shared),
                                 '--scratch-path', str(scratch / 'packages/ChecklistShared'),
                                 'describe', '--type', 'json'], cwd=root, check=True,
                                text=True, capture_output=True)
        package = json.loads(result.stdout)
        products = {product['name']: product['targets'] for product in package.get('products', [])}
        names = {target['name'] for target in graph['targets']}
        for target in package['targets']:
            if target['name'] in names:
                raise ValueError('shared package target name collides with root: ' + target['name'])
            target['package_path'] = package_path
            target['path'] = package_path + '/' + target['path']
        for target in graph['targets']:
            dependencies = set(target.get('target_dependencies', []))
            for product in target.get('product_dependencies', []):
                dependencies.update(products.get(product, ()))
            target['target_dependencies'] = sorted(dependencies)
        graph['targets'].extend(package['targets'])
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


def load_impact_map(root, path=None, max_age_hours=24):
    """Accept only a complete, recent map from an ancestor with stable test inputs.

    Production edits remain eligible for coverage selection; new files use module
    fallback. Changed build inputs, unnamed runtime inputs and nested-package tests
    invalidate the observation environment. Changed test-tree code and runtime
    inputs with named readers keep the map; the planner selects them directly
    and reports them as changed_test_inputs (CL-299).
    """
    from datetime import datetime, timezone
    path = path or root / '.local/build/test-impact-map.json'
    status = {'path': str(path), 'state': 'missing'}
    try:
        data = json.loads(Path(path).read_text())
        if data.get('schema_version') != 1 or data.get('complete') is not True:
            raise ValueError('incomplete or unsupported coverage map')
        generated = datetime.fromisoformat(data['generated_at'].replace('Z', '+00:00'))
        age = (datetime.now(timezone.utc) - generated).total_seconds()
        if age < -300 or age > max_age_hours * 3600:
            raise ValueError('coverage map is old')
        subprocess.run(['git', 'merge-base', '--is-ancestor', data['commit'], 'HEAD'],
                       cwd=root, check=True, capture_output=True)
        drift = changed_paths(root, data['commit'])
        invalidating = [name for name in drift if name.startswith('Tests/') or
                        (name.startswith('Packages/') and ('Tests' in PurePosixPath(name).parts or
                         PurePosixPath(name).name in ('Package.swift', 'Package.resolved'))) or
                        name in ('Package.swift', 'Package.resolved', 'script/test_impact_map.py', 'script/index_store.py') or
                        name in FILE_TEST_CONSUMERS or name in FILE_PYTHON_TEST_CONSUMERS or
                        (name.startswith(('Sources/', 'Packages/')) and
                         PurePosixPath(name).suffix not in ('.swift', '.c', '.h', '.m', '.mm', '.cpp', '.s')) or
                        name.startswith(BUILD_SCRIPTS)]
        # Uncommitted generator changes at refresh time are captured by input hashes.
        invalidating = [name for name in invalidating if not (root / name).is_file() or
                        data.get('input_hashes', {}).get(name) !=
                        hashlib.sha256((root / name).read_bytes()).hexdigest()]
        deferred = [name for name in invalidating if direct_test_input(name)]
        invalidating = [name for name in invalidating if name not in deferred]
        if invalidating:
            raise ValueError('test/build inputs changed: ' + ', '.join(invalidating))
        if set(data.get('qualification_case_inventory', data.get('measured_qualification_cases', []))) != set(QUALIFICATION_CASES):
            raise ValueError('qualification inventory changed')
        if not isinstance(data['sources'], dict):
            raise ValueError('invalid coverage sources')
        for name, entry in data['sources'].items():
            if PurePosixPath(name).is_absolute() or '..' in PurePosixPath(name).parts:
                raise ValueError('coverage map contains an unsafe path')
            if not isinstance(entry, dict):
                raise ValueError('invalid coverage entry')
            if not isinstance(entry.get('classes'), list) or not isinstance(entry.get('qualification_cases'), list):
                raise ValueError('invalid coverage entry')
            if any(not isinstance(group, str) or not re.fullmatch(r'\w+\.\w+', group) for group in entry['classes']):
                raise ValueError('invalid coverage class')
            if any(case not in QUALIFICATION_CASES for case in entry['qualification_cases']):
                raise ValueError('unknown qualification case')
        unmeasurable = data.get('coverage_unmeasurable_classes', {})
        if not isinstance(unmeasurable, dict):
            raise ValueError('invalid unmeasurable coverage classes')
        for group, observation in unmeasurable.items():
            if (not isinstance(group, str) or not re.fullmatch(r'\w+\.\w+', group)
                    or not isinstance(observation, dict)
                    or not isinstance(observation.get('reason'), str)
                    or not observation['reason']
                    or observation.get('source') != 'index-store'
                    or 'max_depth' in observation
                    or not isinstance(observation.get('walk'), dict)
                    or observation['walk'].get('complete') is not True
                    or not isinstance(observation.get('sources'), list)
                    or not observation['sources']):
                raise ValueError('unmeasurable coverage class needs nonempty index-store edges and a complete fixed-point walk')
            for path in observation['sources']:
                if (not isinstance(path, str) or not path or '\\' in path
                        or PurePosixPath(path).is_absolute()
                        or '..' in PurePosixPath(path).parts
                        or PurePosixPath(path).as_posix() != path
                        or not (path.startswith(('Sources/', 'Tests/')) or
                                re.match(r'Packages/[^/]+/(?:Sources|Tests)/', path))
                        or PurePosixPath(path).suffix not in ('.swift', '.c', '.h', '.m', '.mm', '.cpp')):
                    raise ValueError('unmeasurable coverage contains an unsafe path')
                if path not in data['sources']:
                    raise ValueError('index-store edge is absent from source inventory')
        missing_classes = (set(data.get('class_inventory', [])) -
                           set(data.get('measured_classes', [])) - set(unmeasurable))
        missing_cases = (set(data.get('qualification_case_inventory', [])) -
                         set(data.get('measured_qualification_cases', [])))
        if missing_classes or missing_cases:
            raise ValueError('coverage inventory is unmeasured without an explicit class exception')
        status.update(state='current', changed_test_inputs=deferred,
                      unmeasured_qualification_cases=sorted(set(data.get('qualification_case_inventory', [])) - set(data.get('measured_qualification_cases', []))),
                      unmeasured_classes=sorted(set(data.get('class_inventory', [])) - set(data.get('measured_classes', []))),
                      commit=data['commit'], generated_at=data['generated_at'],
                      generation_seconds=data['generation_seconds'])
        return data, status
    except FileNotFoundError:
        return None, status
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        status.update(state='fallback', reason=str(error))
        return None, status


def select(root, graph, paths, scratch, full=False, qualification=False, last_round=False, impact_map=None, runner_wrapper=None, shared_index=None):
    targets = {target['name']: target for target in graph['targets']}
    if impact_map is None:
        impact_map, impact_status = load_impact_map(root)
    else:
        impact_status = {'state': 'supplied' if impact_map.get('complete') else 'incomplete'}
        if not impact_map.get('complete'):
            impact_map = None
    mapped_sources = impact_map.get('sources', {}) if impact_map else {}
    unmeasurable_classes = impact_map.get('coverage_unmeasurable_classes', {}) if impact_map else {}
    all_tests = {name for name, target in targets.items() if target['type'] == 'test'}
    affected, python, unknown = set(), set(), []
    fallback_reasons = {}

    def fallback(path, reason):
        unknown.append(path)
        fallback_reasons[path] = reason
    # Longest target path wins (e.g. StorageCrashProbe/ReleasedCore).
    owners = sorted(targets.values(), key=lambda target: len(target['path']), reverse=True)
    normalized = sorted(set(PurePosixPath(path.removeprefix('./')).as_posix() for path in paths))
    for path in normalized:
        parts = PurePosixPath(path).parts
        if PurePosixPath(path).is_absolute() or '..' in parts:
            fallback(path, 'unsafe path')
        elif path == 'Package.swift' or path == 'Package.resolved':
            fallback(path, 'package manifest or lockfile')
        elif path.startswith('Packages/') and PurePosixPath(path).name in ('Package.swift', 'Package.resolved'):
            fallback(path, 'nested package manifest or lockfile')
        elif path.startswith(BUILD_SCRIPTS):
            fallback(path, 'build script')
        elif path in FILE_TEST_CONSUMERS or path in FILE_PYTHON_TEST_CONSUMERS:
            consumers = FILE_TEST_CONSUMERS.get(path, ())
            python_consumers = FILE_PYTHON_TEST_CONSUMERS.get(path, ())
            if any(name not in all_tests for name in consumers) or any(
                    not (root / name).is_file() for name in python_consumers):
                fallback(path, 'named runtime reader is missing from the package or scripts')
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
                fallback(path, 'not a source or resource of a package target')
        elif path in PYTHON_TEST_OWNERS or (path.endswith('.py') and path.startswith(('script/', 'scripts/'))):
            own_tests = python_tests(root, path)
            if own_tests is not None:
                python.update(own_tests)
            else:
                fallback(path, 'Python file without a test owner')
        elif path in VALIDATION_ONLY_FILES or any(
                fnmatchcase(path, pattern) for pattern in VALIDATION_ONLY_GLOBS):
            pass
        else:
            fallback(path, 'unknown path; its consumers cannot be determined')
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
    # CL-299: with a current map, changed test files and named runtime inputs
    # select their own classes and measured consumers instead of the map falling back.
    direct, direct_fallbacks, declared = {}, {}, {}
    for path in normalized if impact_map else ():
        owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
        if owner and owner['type'] == 'test' and direct_test_input(path):
            selection = test_file_selection(root, targets, owner, path, impact_map, declared)
        elif path in FILE_TEST_CONSUMERS and direct_test_input(path):
            selection = runtime_input_selection(root, targets, path, impact_map, declared)
        else:
            continue
        if 'fallback' in selection:
            direct_fallbacks[path] = selection['fallback']
        else:
            direct[path] = selection
    shared_paths = [path for path in normalized if any(
        target.get('package_path') and target['type'] != 'test' and path.startswith(target['path'] + '/')
        for target in owners)]
    shared_classes, shared_index_reason = {}, 'no current shared-package index export; module closure'
    if shared_paths and shared_index is not None:
        try:
            # The helper validates the indexed source inventory before narrowing.
            import importlib.util
            spec = importlib.util.spec_from_file_location('shared_test_impact', Path(__file__).with_name('shared_test_impact.py'))
            helper = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(helper)
            shared_classes = helper.shared_source_classes(root, shared_index, shared_paths)
        except (ValueError, OSError) as error:
            shared_index_reason = 'shared-package index unavailable: ' + str(error) + '; module closure'
    new_sources = [path for path in normalized if impact_map and path not in mapped_sources and path not in shared_paths
                   and path.endswith('.swift') and (root / path).is_file()
                   and (owner := next((target for target in owners if path.startswith(target['path'] + '/')), None))
                   and owner['type'] != 'test']
    reached, new_source_reasons = new_source_reachability(root, normalized, new_sources)
    if last_round:
        affected.update(targets)
    if unknown or full:
        affected.update(targets)
        python.update(str(path.relative_to(root)) for path in (root / 'scripts').glob('test_*.py'))
    tests = sorted(all_tests.intersection(affected))
    explicitly_qualified = qualification or last_round
    qualification_mode = ('requested-full' if qualification else 'pass-final-round' if last_round
                          else 'full-default' if full else 'affected')
    reasons = {case: [] for case in QUALIFICATION_CASES}
    source_groups, group_fallback_paths = {}, []
    qualification_fallback_cases, coverage_fallback_classes = {}, {}
    selected_unmeasurable_classes = {}
    for path in normalized:
        if path in reached:
            # Its changed referencing files carry the selection (CL-299).
            source_groups[path] = {}
            continue
        if path in direct:
            selection = direct[path]
            mapping = {name: sorted(classes) for name, classes in selection['classes'].items()}
            source_groups[path] = mapping
            affected.update(mapping)
            affected.update(selection['broad'])
            for case in QUALIFICATION_CASES:
                if case in selection['cases']:
                    reasons[case].append(path)
            continue
        entry = mapped_sources.get(path)
        if path in shared_classes:
            entry = {'classes': sorted(set(shared_classes[path]) | set(entry['classes'] if entry else ())),
                     'qualification_cases': list(entry['qualification_cases']) if entry else []}
            # Static reachability includes any registered qualification method in a selected class.
            entry['qualification_cases'] = sorted(set(entry['qualification_cases']) | {
                case for case in QUALIFICATION_CASES if case.split('/')[0] in shared_classes[path]})
        elif path in shared_paths and not (entry and (entry['classes'] or entry['qualification_cases'])):
            # Root coverage may inventory a shared declaration with no instrumented
            # hits. An empty entry does not prove that the module has no consumers.
            entry = None
        owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
        if entry is not None:
            mapping = {}
            for group in entry['classes']:
                name, separator, cls = group.partition('.')
                if separator and name in all_tests:
                    mapping.setdefault(name, []).append(cls)
            # Forbidden/native-only classes have no measured profile. Their
            # index-store references are explicit source edges, never module closure.
            for group, observation in sorted(unmeasurable_classes.items()):
                name, separator, cls = group.partition('.')
                if separator and name in all_tests and path in observation['sources']:
                    mapping.setdefault(name, []).append(cls)
                    selected_unmeasurable_classes.setdefault(group, []).append(path)
            source_groups[path] = mapping
            affected.update(mapping)
            for case in entry['qualification_cases']:
                if case in reasons:
                    reasons[case].append(path)
        elif owner and owner['type'] != 'test':
            group_fallback_paths.append(path)
            fallback_reasons[path] = ('source file is not in the coverage map; module closure' if impact_map
                                      else 'no current coverage map; module closure')
            if path in shared_paths:
                fallback_reasons[path] = shared_index_reason
            if path in new_source_reasons:
                fallback_reasons[path] += ' (' + new_source_reasons[path] + ')'
            for case in QUALIFICATION_CASES:
                if case.split('.')[0] in path_consumers[path]:
                    reasons[case].append(path)
        elif owner and owner['type'] == 'test':
            # An unmapped/changed fixture needs all qualifiers in its target.
            if path in direct_fallbacks:
                group_fallback_paths.append(path)
                fallback_reasons[path] = direct_fallbacks[path] + '; whole target'
            for case in QUALIFICATION_CASES:
                if case.split('.')[0] in path_consumers[path]:
                    reasons[case].append(path)
    qualification_tests = (list(QUALIFICATION_CASES) if explicitly_qualified else
                           [] if full else [case for case in QUALIFICATION_CASES if reasons[case]])
    qualification = bool(qualification_tests)
    tests = sorted(all_tests.intersection(affected))
    groups = {}
    if not full and not unknown and not last_round:
        for name in tests:
            relevant = []
            for path in normalized:
                mapping = source_groups.get(path)
                owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
                if targets[name].get('package_path') and name in path_consumers[path]:
                    # Root coverage/index observations do not execute nested tests.
                    relevant.append(test_file_groups(root, owner, path) if owner and owner['name'] == name else None)
                elif mapping is not None:
                    # A complete coverage refresh includes dependent test targets.
                    relevant.append(None if name in direct.get(path, {}).get('broad', ()) else mapping.get(name, ()))
                elif name not in path_consumers[path]:
                    continue
                elif name in FILE_TEST_CONSUMERS.get(path, ()):
                    relevant.append(None)
                elif owner and owner['name'] == name:
                    relevant.append(test_file_groups(root, owner, path))
                elif owner:
                    # Production modules and source-inspection readers of test trees.
                    relevant.append(None)
            if relevant and all(selected is not None for selected in relevant):
                groups[name] = sorted({group for selected in relevant for group in selected})
        tests = [name for name in tests if name not in groups or groups[name]]
        groups = {name: selected for name, selected in groups.items() if name in tests}
    # Qualification is independent of unit group narrowing: an explicitly requested
    # full qualification includes Core/App/IPC cases even for a docs-only change.
    skip = [case for case in QUALIFICATION_CASES if case not in qualification_tests] if tests else []
    root_tests = [name for name in tests if not targets[name].get('package_path')]
    shared_tests = [name for name in tests if targets[name].get('package_path')]
    swift = []
    isolated = []
    qualification_commands = []
    timing_tests, timing_commands, timing_deferred = [], [], False
    if root_tests or full or qualification_tests:
        command = ['swift', 'test', '--parallel', '--num-workers', '10', '--cache-path',
                   str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                   '--enable-dependency-cache', '--scratch-path', str(scratch), '--skip', 'HumanClaimsKeychainTests']
        if not full:
            for target in root_tests:
                suffix = '(?:' + '|'.join(re.escape(group) for group in groups[target]) + r')(?:/|$)' if target in groups else ''
                command.extend(['--filter', '^' + re.escape(target) + r'\.' + suffix])
        for case in QUALIFICATION_CASES + ISOLATED_TESTS:
            command.extend(['--skip', '^' + re.escape(case) + r'(?:/|$)'])
        if 'ChecklistCoreTests' in tests or any(case.startswith('ChecklistCoreTests.') for case in qualification_tests):
            command = ['env', 'CHECKLIST_STORAGE_PROBE=' + str(scratch / 'out/Products/Debug/StorageCrashProbe')] + command
        command = ['env', 'CHECKLIST_TEST_TEMPLATE_ROOT=' + str(scratch / 'test-store-templates'),
                   'CHECKLIST_QUALIFICATION=0'] + command
        isolated = [group for group in ISOLATED_TEST_GROUPS
                    if group.split('.')[0] in tests and (group.split('.')[0] not in groups
                    or group.split('.')[1] in groups[group.split('.')[0]])]
        for group in isolated:
            command.extend(['--skip', '^' + re.escape(group) + r'(?:/|$)'])
        if root_tests or full:
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
                          '--enable-dependency-cache', '--scratch-path', str(scratch), '--skip', 'HumanClaimsKeychainTests'])
            for case in timing_tests:
                timed.extend(['--filter', '^' + re.escape(case) + '$'])
            timing_commands.append(timed)
            swift.append(timed)
        if qualification_tests:
            qualified = command[:command.index('swift') + 2]
            qualified = ['CHECKLIST_QUALIFICATION=1' if arg == 'CHECKLIST_QUALIFICATION=0' else arg for arg in qualified]
            qualified.extend(['--parallel', '--num-workers', '1', '--cache-path',
                              str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                              '--enable-dependency-cache', '--scratch-path', str(scratch), '--skip', 'HumanClaimsKeychainTests'])
            for case in qualification_tests:
                qualified.extend(['--filter', '^' + re.escape(case) + '$'])
            qualification_commands.append(qualified)
            swift.append(qualified)
    refresh_commands = []
    if last_round:
        refresh = ['python3', 'script/test_impact_map.py', '--scratch-path', str(scratch)]
        if runner_wrapper:
            refresh.extend(['--runner-wrapper', str(runner_wrapper)])
        refresh_commands.append(refresh)
        swift = []  # The refresh executes each class and qualification case once.
        qualification_commands = []
        timing_commands = []
    shared_commands = []
    for package_path in sorted({targets[name]['package_path'] for name in shared_tests}):
        command = ['swift', 'test', '--package-path', str(root / package_path),
                   '--cache-path', str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                   '--enable-dependency-cache', '--scratch-path',
                   str(scratch / 'packages' / Path(package_path).name), '--skip', 'HumanClaimsKeychainTests']
        for target in shared_tests:
            if targets[target]['package_path'] != package_path:
                continue
            suffix = '(?:' + '|'.join(re.escape(group) for group in groups[target]) + r')(?:/|$)' if target in groups else ''
            command.extend(['--filter', '^' + re.escape(target) + r'\.' + suffix])
        shared_commands.append(command)
    swift.extend(shared_commands)
    # uv supplies the dependencies needed by the exporter/validator tests too.
    python_commands = [SCRIPT_PYTHON + [path] for path in sorted(python)]
    return {'paths': normalized, 'affected_targets': sorted(affected), 'test_targets': tests,
            'python_tests': sorted(python), 'fallback_paths': unknown, 'skip': skip, 'full': full, 'qualification': qualification,
            'isolated_test_groups': isolated, 'test_groups': groups,
            'group_fallback_paths': group_fallback_paths, 'qualification_mode': qualification_mode,
            'fallback_reasons': {path: fallback_reasons[path] for path in unknown + group_fallback_paths
                                 if path in fallback_reasons},
            'direct_test_selections': {path: {'reason': selection['reason'],
                                              'classes': sorted(name + '.' + cls for name, values in selection['classes'].items()
                                                                for cls in values),
                                              'qualification_cases': sorted(selection['cases']),
                                              'whole_targets': sorted(selection['broad'])}
                                       for path, selection in sorted(direct.items())},
            'new_source_reachability': {path: {'reason': 'new source: its names are new to the repository; '
                                                         'changed files that name it carry the selection',
                                               'referenced_by': users} for path, users in reached.items()},
            'qualification_fallback_cases': qualification_fallback_cases, 'coverage_fallback_classes': coverage_fallback_classes,
            'coverage_unmeasurable_classes': selected_unmeasurable_classes,
            'test_group_sources': {group: {'source': 'index-store', 'paths': paths}
                                   for group, paths in sorted(selected_unmeasurable_classes.items())},
            'qualification_reasons': {case: reasons[case] for case in qualification_tests},
            'default_swift_commands': [command for command in swift if command not in qualification_commands and command not in timing_commands],
            'qualification_commands': qualification_commands, 'qualification_tests': qualification_tests,
            'qualification_test_targets': sorted({case.split('.')[0] for case in qualification_tests}),
            'timing_commands': timing_commands, 'timing_tests': timing_tests, 'timing_deferred': timing_deferred,
            'shared_package_commands': shared_commands,
            'shared_index_selections': shared_classes, 'shared_index_fallback_reason': shared_index_reason if shared_paths and not shared_classes else None,
            'swift_commands': swift, 'coverage_refresh_commands': refresh_commands, 'impact_map_status': impact_status,
            'commands': swift + refresh_commands + python_commands + [VALIDATE]}


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
    parser.add_argument('--shared-index', type=Path, help='portable compiler-index export for shared source consumers')
    parser.add_argument('--impact-map', type=Path, help='coverage map (default .local/build/test-impact-map.json)')
    parser.add_argument('--map-max-age-hours', type=float, default=24)
    parser.add_argument('--runner-wrapper', type=Path, help='shared build-cap wrapper for final-round refresh')
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
        impact_map, impact_status = load_impact_map(root, args.impact_map, args.map_max_age_hours)
        index_path = args.shared_index or scratch / 'affected-tests/shared-index.json'
        shared_index = None
        if any(PurePosixPath(path.removeprefix('./')).as_posix().startswith(
                'Packages/ChecklistShared/Sources/') for path in paths):
            try:
                shared_index = json.loads(index_path.read_text()) if index_path.is_file() else None
            except (OSError, ValueError):
                # A damaged optional index must leave a runnable conservative plan.
                shared_index = {'invalid': True}
        plan = select(root, package_graph(root, scratch), paths, scratch, args.full, args.qualification, args.last_round,
                      impact_map if impact_map is not None else {'complete': False}, args.runner_wrapper, shared_index)
        plan['impact_map_status'] = impact_status
        if args.json:
            print(json.dumps(plan, indent=2))
        else:
            print('Coverage map: ' + json.dumps(plan['impact_map_status'], sort_keys=True))
            print('Unit test targets: ' + (', '.join(plan['test_targets']) or '(none)'))
            print('Qualification mode: ' + plan['qualification_mode'])
            print('Qualification targets: ' + (', '.join(plan['qualification_test_targets']) or '(none)'))
            for case, paths in plan['qualification_reasons'].items():
                print('Qualification case: ' + case + ' <- ' + (', '.join(paths) or plan['qualification_mode']))
            for case, inputs in plan['qualification_fallback_cases'].items():
                print('Unmeasured qualification fallback: ' + case + ' <- ' + ', '.join(inputs))
            for group, inputs in plan['coverage_fallback_classes'].items():
                print('Unmeasured class fallback: ' + group + ' <- ' + ', '.join(inputs))
            for group, observation in plan['test_group_sources'].items():
                print('Unmeasurable class index-store references: ' + group + ' <- ' +
                      ', '.join(observation['paths']))
            for path, classes in plan['shared_index_selections'].items():
                print('Shared-package index: ' + path + ' -> ' + str(len(classes)) + ' root classes')
            for path, selection in plan['direct_test_selections'].items():
                print('Direct test-file selection: ' + path + ' -> ' + (', '.join(selection['classes']) or '(none)') +
                      ' (' + selection['reason'] + ')')
            for path, selection in plan['new_source_reachability'].items():
                print('New source reached through: ' + path + ' <- ' + ', '.join(selection['referenced_by']))
            if plan['group_fallback_paths']:
                print('Module group fallback for: ' + ', '.join(plan['group_fallback_paths']))
            for path, reason in plan['fallback_reasons'].items():
                print('Fallback reason: ' + path + ': ' + reason)
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
