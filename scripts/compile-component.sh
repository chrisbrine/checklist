#!/bin/bash
# Compile one standalone check-*.swift harness from the repository root.
# When a production input gains a dependency, add its real source to that case,
# update the harness's isolated Store fixture if needed, then compile every case.
# --scratch-path owns all compiler caches, IPC artifacts and output executables.
set -euo pipefail
if [[ $# != 3 || $1 != --scratch-path ]]; then
    echo 'Usage: bash scripts/compile-component.sh --scratch-path DIR check-NAME' >&2
    exit 2
fi
mkdir -p "$2"
component_build=$(cd "$2" && pwd)
component=$3
app=Sources/ChecklistApp
sources=()
link=(-module-cache-path "$component_build/module-cache")
case "$component" in
    check-frame-observer-lifetime|check-native-escape-routing|check-native-frame-lifecycle)
        sources+=("$app/Support/DetailOverlayInteraction.swift" "$app/Support/DetailOverlayOpeningControl.swift") ;;
    check-overlay-interactions)
        sources+=("$app/Support/DetailOverlayInteraction.swift" "$app/Support/DetailOverlayOpeningControl.swift") ;;
    check-item-navigation-ownership|check-recreated-swiftui-focus|check-navigation-retention)
        sources+=("$app/Models/Record.swift" "$app/Models/RecordIdentity.swift" "$app/Support/DetailItemStateRetention.swift")
        if [[ $component == check-item-navigation-ownership ]]; then link+=(-O); fi
        if [[ $component == check-navigation-retention ]]; then
            sources+=("$app/Support/Canceled.swift" "$app/Models/TicketVisibility.swift" "$app/Models/TicketListProjection.swift" "$app/Models/TicketListRows.swift" "$app/Support/RecordOrdering.swift" "$app/Support/TicketListStability.swift")
        fi ;;
    check-settings-modal|check-ticket-layout-replay)
        for name in Design TextScale DisplayCaches Canceled DisabledReason DetailOverlayInteraction DetailOverlayOpeningControl; do
            sources+=("$app/Support/$name.swift")
        done
        if [[ $component == check-settings-modal ]]; then
            sources+=("$app/Support/SettingsModalPresentation.swift")
        else
            for name in Record RecordIdentity TicketVisibility TicketListProjection TicketListRows TicketWorkspacePreparation SnapshotRecordIndex TicketBulkSelection TicketPage PersonalTicketView TaskRowPresentation; do
                sources+=("$app/Models/$name.swift")
            done
            for name in RecordOrdering TicketListStability NativeRenderMetrics ProductionGroups TicketKeyboardNavigation Confirmations PlainError; do
                sources+=("$app/Support/$name.swift")
            done
            for name in InlineTriageRow TaskWorkspaceView TicketStatusPills; do
                sources+=("$app/Views/$name.swift")
            done
            xcrun swiftc -swift-version 5 -module-cache-path "$component_build/module-cache" -emit-library -emit-module -module-name ChecklistIPC Sources/ChecklistIPC/Protocol.swift Sources/ChecklistIPC/ChecklistInstance.swift -emit-module-path "$component_build/ChecklistIPC.swiftmodule" -o "$component_build/libChecklistIPC.dylib"
            # Parse the larger replay input set once instead of once per file.
            link+=(-whole-module-optimization -I "$component_build" -L "$component_build" -lChecklistIPC -Xlinker -rpath -Xlinker "$component_build")
        fi ;;
    *) echo "Unknown component harness: $component" >&2; exit 2 ;;
esac
xcrun swiftc -swift-version 5 -parse-as-library "${link[@]}" "${sources[@]}" "scripts/$component.swift" -o "$component_build/$component"
echo "$component_build/$component"
