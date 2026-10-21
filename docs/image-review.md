# Image inspection and round comparison

CL-75 uses the shared [file-preview layer](attachments.md#shared-native-file-previews-cl-121). A ticket's immutable submission is its image-review round. The large comparison sheet groups images by exact view name and shows the selected submission beside its immediate previous submission. Missing history and ambiguous view matches are explicit, never silently replaced with a later candidate. Internal taskless media rounds, context attention and owner decisions keep their existing contracts; this ticket does not activate their commands or change `MediaRounds.swift`.

A submitted `evidence_manifest.artifact_refs` entry may include declarative `view_name` and `preview_presentation` metadata alongside its existing `artifact_id` and `sha256`. This metadata belongs to that immutable manifest/digest and changes no file grant. Example:

```json
{
  "artifact_id": "synthetic-front-image",
  "sha256": "<original SHA-256>",
  "view_name": "front",
  "preview_presentation": {
    "scale": "actual_pixels",
    "nearest_neighbor": true,
    "sprite_sheet": {"columns": 4, "rows": 2, "frame_count": 8, "frames_per_second": 8}
  }
}
```

Ordinary filenames supply a default view name: the filename stem without a final `-round2`, `_r2` or `-v2` suffix. Explicit view names are preferable for irregular names. Different current images with the same view name remain separate candidates; the UI does not guess a winner or pair an ambiguous previous candidate. A round never selects a replacement file by name: every pane retains its exact attachment/hash/manifest binding.

The selected-ticket read supplies a separate read-only `review_target_history` presentation context for the current and immediately preceding submission, with at most 1,000 artifact refs per target. The submission chooser and comparison receive both immutable manifests (including measures) and their exact attachment metadata. The service identifies the predecessor by ticket-local insertion order without exposing an internal sequence. Equal timestamps and identical content hashes in different named views do not collapse candidates. This presentation context adds no historical claims, requests or verdicts to current action authority. The earlier target remains selectable from the chooser or its finding; its measurements and warnings stay bound to that target. Older history outside these two targets remains explicitly unavailable in this presentation context.

The comparison sheet supports a large native image viewer, Fit and Actual pixels (one source pixel per physical display pixel at 100%), pixel zoom, nearest-neighbor scaling, and checkerboard transparency. Space opens the selected verified original copy in Quick Look; the labeled Quick Look button provides the same action. Closing Quick Look returns to the comparison. Viewing and external opening never mark an image inspected automatically. GIF frames decode on demand. Play/Pause, previous/next frame and a frame picker provide frame-by-frame review. Sprite sheets accept the manifest grid or explicit local display controls; cells must divide the original dimensions exactly. Display controls do not edit source files or target metadata. Playback is explicit and stops when its pane closes. Limits are 80 million source pixels, 1,000 frames/grid cells and the shared 500 MiB original bound. Native decoders may finish an in-flight bounded call after cancellation; late results are discarded.

An inspection selection is a separate explicit checkbox/button. Its wire value is `inspected_images: [{artifact_id, sha256, target_manifest_id}]`. Human exact-target image approval and passing image artifact reviews require marks for every image in the target being approved; reject/blocked outcomes may record only the inspected subset. Each entry must belong to this exact target and hash; duplicates, unknown entries, other targets and non-image entries are rejected. Viewing does not mint human provenance; only trusted `human_request_answer` can record an owner's selection. Agent `review_record` and its draft/batch routes retain actual reviewer authority and independence. Records preserve the normalized inspected list on the verdict and owner response. Saved marks from an older form/target do not qualify a new target.

A cleaned, missing, changed or unavailable original cannot be marked from a retained thumbnail. The service validates original availability and exact hashes again when accepting a verdict. A missing previous-round original says unavailable in its pane; it does not substitute a retained preview for reinspection of the current candidate. Opening files and checking inspection marks are never approval actions. The owner still chooses a result and sends an answer; agents still submit their own explicit verdict through the existing gate workflow.

Installed qualification is separate from source tests. Use the synthetic fixtures and bounded check plan in the helper's report, then record observations for the exact installed build. Do not infer Quick Look keyboard behavior or responsive native decoding from a successful compile.
