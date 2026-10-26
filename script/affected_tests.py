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
# Compatibility name for consumers of the original selector plan.
HEAVY_TESTS = QUALIFICATION_CASES
ISOLATED_TESTS = TIMING_TESTS + LOAD_SENSITIVE_TESTS
# macOS Seatbelt positive controls fail with SIGKILL when Git probes overlap.
# Keep native guards intact and isolate this class from all other test work.
ISOLATED_TEST_GROUPS = ('ChecklistCoreTests.SourceGitConfinementTests',
                        'ChecklistMCPServerTests.DelegateChildBindingTests')
# Heavy fixtures instantiate CommandRouter and exercise shared models, hashing,
# imports, persistence and provider policy. No Core source is proven unreachable.
HEAVY_MODULES = ('ChecklistCore', 'ChecklistIPC', 'ChecklistApp')
HEAVY_SOURCE_PREFIXES = ('Sources/ChecklistApp/Media/', 'Tests/ChecklistTestSupport/')
# Explicit validation-only families; runtime inputs below take precedence.
# Other non-code files (including arbitrary Markdown and docs binary fixtures)
# have unknown impact and select the full suite.
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
# Small, closed entry points whose tests are narrower than their SwiftPM module.
# The grammar and ordinary-note command behavior have a dedicated boundary
# group. Dependent targets stay broad; the migration fixture reads stored types.
# Unmapped Core source changes retain whole-target coverage.
SOURCE_TEST_GROUPS = {
    'Sources/ChecklistCore/OrdinaryMentionTokens.swift': {
        'ChecklistCoreTests': ('OrdinaryMentionPublicBoundaryTests',),
    },
}


SOURCE_GROUP_SYMBOLS = {
    'Sources/ChecklistCore/OrdinaryMentionTokens.swift': (
        'OrdinaryMentionTokens', {'Sources/ChecklistCore/OrdinaryMentionTokens.swift', 'Sources/ChecklistCore/OrdinaryMentionCommands.swift'}),
}


def source_test_groups(root, path):
    mapping = SOURCE_TEST_GROUPS.get(path, {})
    if path in SOURCE_GROUP_SYMBOLS:
        symbol, expected = SOURCE_GROUP_SYMBOLS[path]
        readers = {source.relative_to(root).as_posix() for source in (root / 'Sources/ChecklistCore').rglob('*.swift')
                   if re.search(r'\b' + re.escape(symbol) + r'\b', source.read_text())}
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


def changed_qualification_tests(root, paths):
    # Registered real-size fixtures need not call the opt-in gate themselves.
    selected = set()
    for path in paths:
        if path == 'Tests/ChecklistCoreTests/QualificationSuite.swift':
            return list(QUALIFICATION_CASES)
        source = root / path
        if path.startswith('Tests/') and source.suffix == '.swift' and source.is_file():
            methods = re.findall(r'func (test\w+)\(', source.read_text())
            selected.update(case for case in QUALIFICATION_CASES if case.split('/')[1] in methods)
    return [case for case in QUALIFICATION_CASES if case in selected]


def select(root, graph, paths, scratch, full=False, qualification=False):
    targets = {target['name']: target for target in graph['targets']}
    all_tests = {name for name, target in targets.items() if target['type'] == 'test'}
    affected, changed_targets, python, unknown = set(), set(), set(), []
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
            if owner and is_target_resource(root, owner, path):
                affected.add(owner['name'])
                changed_targets.add(owner['name'])
        elif path.startswith(('Sources/', 'Tests/')) or any(
                path.startswith(target['path'] + '/') for target in owners):
            owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
            if owner and (PurePosixPath(path).suffix in ('.swift', '.c', '.h', '.m', '.mm', '.cpp', '.s')
                          or is_target_resource(root, owner, path)):
                affected.add(owner['name'])
                changed_targets.add(owner['name'])
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
    # Reverse dependency closure includes executable modules and their consumers.
    while True:
        dependents = {name for name, target in targets.items()
                      if affected.intersection(target.get('target_dependencies', []))}
        for producer, consumers in RUNTIME_TEST_CONSUMERS.items():
            if producer in affected:
                dependents.update(name for name in consumers if name in targets)
        added = dependents - affected
        if not added:
            break
        affected.update(added)
    if unknown or full:
        affected.update(targets)
        python.update(str(path.relative_to(root)) for path in (root / 'scripts').glob('test_*.py'))
    tests = sorted(all_tests.intersection(affected))
    # Follow forward dependencies of the heavy tests' production module too:
    # a Providers change can affect Core's policy and data behavior.
    heavy_dependencies = set(HEAVY_MODULES)
    pending = list(HEAVY_MODULES)
    while pending:
        for dependency in targets.get(pending.pop(), {}).get('target_dependencies', []):
            if dependency not in heavy_dependencies:
                heavy_dependencies.add(dependency)
                pending.append(dependency)
    heavy_changed = bool(changed_targets.intersection(heavy_dependencies)) or any(
        path.startswith(HEAVY_SOURCE_PREFIXES) for path in normalized)
    changed_qualifiers = changed_qualification_tests(root, normalized)
    explicitly_qualified = qualification
    qualification = qualification or (not full and (bool(unknown) or heavy_changed or bool(changed_qualifiers)))
    source_groups = {path: source_test_groups(root, path) for path in normalized}
    groups = {}
    if not full and not unknown:
        for name in tests:
            relevant = []
            for path in normalized:
                mapping = source_groups[path]
                owner = next((target for target in owners if path.startswith(target['path'] + '/')), None)
                if name in mapping:
                    relevant.append(mapping[name])
                elif name in FILE_TEST_CONSUMERS.get(path, ()):
                    relevant.append(None)
                elif owner and owner['name'] == name:
                    relevant.append(test_file_groups(root, owner, path))
                elif owner and owner['type'] != 'test':
                    relevant.append(None)
            if relevant and all(relevant):
                groups[name] = sorted({group for selected in relevant for group in selected})
    # Group narrowing applies to the fast unit suite. Qualification retains
    # the production dependency closure: ordinary-note parsing also runs in
    # the writer-traffic and scale fixtures.
    qualification_tests = (list(QUALIFICATION_CASES) if qualification and
                           (explicitly_qualified or heavy_changed or unknown or full) else
                           changed_qualifiers if qualification else [])
    qualification_tests = [case for case in qualification_tests if case.split('.')[0] in tests]
    skip = [case for case in QUALIFICATION_CASES if case not in qualification_tests] if tests else []
    swift = []
    isolated = []
    qualification_commands = []
    timing_tests, timing_commands, timing_deferred = [], [], False
    if tests or full:
        command = ['swift', 'test', '--parallel', '--num-workers', '10', '--cache-path',
                   str(Path.home() / 'Library/Caches/ChecklistSwiftPM'),
                   '--enable-dependency-cache', '--scratch-path', str(scratch)]
        if not full:
            for target in tests:
                suffix = '(?:' + '|'.join(re.escape(group) for group in groups[target]) + r')(?:/|$)' if target in groups else ''
                command.extend(['--filter', '^' + re.escape(target) + r'\.' + suffix])
        for case in QUALIFICATION_CASES + ISOLATED_TESTS:
            command.extend(['--skip', '^' + re.escape(case) + r'(?:/|$)'])
        if 'ChecklistCoreTests' in tests:
            command = ['env', 'CHECKLIST_STORAGE_PROBE=' + str(scratch / 'out/Products/Debug/StorageCrashProbe')] + command
        command = ['env', 'CHECKLIST_TEST_TEMPLATE_ROOT=' + str(scratch / 'test-store-templates'), 'CHECKLIST_QUALIFICATION=0'] + command
        isolated = [group for group in ISOLATED_TEST_GROUPS
                    if group.split('.')[0] in tests and (group.split('.')[0] not in groups
                    or group.split('.')[1] in groups[group.split('.')[0]])]
        for group in isolated:
            command.extend(['--skip', '^' + re.escape(group) + r'(?:/|$)'])
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
        # qualification runs (--qualification, every round commit) or when a
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
            'default_swift_commands': [command for command in swift if command not in qualification_commands and command not in timing_commands],
            'qualification_commands': qualification_commands, 'qualification_tests': qualification_tests,
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
    parser.add_argument('--json', action='store_true', help='emit the plan as JSON argv arrays')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--scratch-path', type=Path, default=Path('.build'))
    args = parser.parse_args(argv)
    if not any((args.base, args.paths, args.paths_file, args.full)):
        parser.error('supply --base, --paths, --paths-file or --full')
    root = args.root.resolve()
    scratch = args.scratch_path.resolve()
    try:
        paths = args.paths or []
        if args.base:
            paths = changed_paths(root, args.base)
        elif args.paths_file:
            contents = sys.stdin.read() if str(args.paths_file) == '-' else args.paths_file.read_text()
            paths = contents.splitlines()
        plan = select(root, package_graph(root, scratch), paths, scratch, args.full, args.qualification)
        if args.json:
            print(json.dumps(plan, indent=2))
        else:
            print('Test targets: ' + (', '.join(plan['test_targets']) or '(none)'))
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
