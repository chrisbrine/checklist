# Routine canonical record retention

Routine maintenance can retire stale cleanup previews. Preparation selects only
that canonical family under the existing batch limit. Apply rechecks the
selected rows in its deadline-bounded transaction. The retention allowlist
keeps delivery receipts and attachment-import jobs out of both steps. These
families add no separate background scan or writer step.

## Attachment-import jobs

- Keep successful settled jobs with their original project, command, digest,
  attachment ID and object descriptors. The job protects the matching
  principal and command ID during command-result pruning and binds exact replay
  to the original scope. When an original read detects missing or damaged
  bytes, the exact job can reenter repair. Repair needs the original matching
  command receipt and managed object descriptors.
- Keep canceled jobs, including jobs whose staging cleanup completed. Their
  cancellation fence prevents retry and publication. Incomplete cleanup still
  needs the existing job and its staging ownership.
- Keep abandoned jobs and jobs whose references or outcome are unresolved. The
  original intent still reserves its identity, and a missing attachment or
  receipt supplies no evidence that the intent or its bytes can be retired.

## Delivery receipts

- Keep the receipt for a current recipient generation at every age. The
  recipient can pick up the original message and explicitly acknowledge the
  exact delivery ID. Pickup leaves acknowledgment to the recipient. Native
  transport age limits control admission to push.
- Keep receipts for closed, changed or quarantined generations. Their
  original IDs and outcomes remain part of scoped history, late transport
  reconciliation, duplicate suppression and resumption lineage. A resumption
  that qualifies for a new delivery uses a separate current-generation receipt.
- Keep receipts with missing messages, unresolved generations or unreadable
  data. An unresolved link supplies no authority to retire a receipt or infer
  acknowledgment.

Routine retention removes zero canonical rows from these two families under
the current contracts. Explicit ticket purge and media deletion have their own
authorization and reference checks.
