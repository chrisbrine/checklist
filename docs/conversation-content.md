# Conversation and field content contract

**Status (CL-127 source).** Version 1 is implemented in source for one field only: the optional `content` companion of `message_send` `body` (ticket notes and Triage-subject notes), with the shared native renderer described in [current source support](#current-source-support-cl-127). It is not installed or qualified until the round runner records the installed check. Every other companion in this document remains a planned contract. Plain strings and Markdown remain the default. The current [file preview contract](attachments.md#shared-native-file-previews-cl-121), where Markdown HTML remains literal, keeps its existing behavior. No existing text field interprets HTML.

The same content model serves ticket notes, [Triage notes to an orchestrator](triage-orchestrators.md#message-routing), Human Request explanations, and other explicitly supported text fields. Rendering is presentation. It never supplies identity, authorization, workflow actions, inspected-image marks, review evidence, or owner approval.

The prepared [content schema](../contracts/conversation-content.schema.json) and [synthetic example](../examples/conversation-content.json) describe the optional v1 envelope, separate from the containing plain string and message routing. JSON shape does not prove fallback equivalence, safe parsed HTML/CSS, aggregate limits, file authority, or evidence validity. Those service and renderer checks are required before activation.

## Current source support (CL-127)

- **Command.** `message_send` advertises an optional closed `content` object (`schema_version` 1 and 1–32 blocks). No other command accepts a companion. The service validates the complete envelope before any write. It refuses a mismatch of the joined fallbacks and `body` with `CONTENT_FALLBACK_MISMATCH`, an unsupported version with `CONTENT_VERSION_UNSUPPORTED`, an invalid block, HTML/CSS construct or limit with `INVALID_CONTENT` (the error names the field path and reason), and a media block that does not cite an attachment of the same ticket with its exact `sha256` with `CONTENT_REFERENCE_UNAVAILABLE`. A plain sender is unchanged.
- **Stored record.** The message record keeps `body` unchanged and adds `content` (the accepted envelope), `content_schema_version` (1) and `content_digest`. The digest is the lowercase hexadecimal SHA-256 of the canonical JSON (sorted keys, unescaped slashes) of `{"text": body, "content": envelope}`. Author, origin, correction and delivery fields keep their existing rules. The record family and envelope decoding are unchanged: stored records keep unknown fields, so backup, snapshot, export and restore carry the three fields as ordinary message data. A `task_context` preview that shortens a note body omits its companion and sets `content_omitted=true`.
- **Renderer.** One SwiftUI view (`RichTextView`) renders ticket notes, Triage-subject notes, the ticket brief, the Triage purpose, review reasons and Human Request explanations. Each field has an explicit capability: notes accept all v1 block types; the other fields render Markdown only and show a stored companion as text with **Rich view unavailable**. Charts use the bundled Swift Charts renderer with a **Chart data** table. HTML is parsed into the allowlisted model and drawn with native views; there is no web view. Links open only on a click, and only `https:` links. Media blocks reuse the attachment row (Preview, Open in…, availability) and load nothing implicitly; markdown images are not fetched.
- **Fallback, source and copy.** **Show source** shows the exact stored string, the stored envelope and the content digest. **Copy source** copies the exact string. **Copy source and content (JSON)** copies `{"export":"original_source","text":…,"content":…}`. Preparation of an envelope or of text larger than 16 KiB runs off the main thread and is canceled when the field changes. Text larger than 262,144 bytes shows a plain prefix with a notice. Malformed or unsupported content shows the string with **Rich view unavailable** and the reason. Rendering adds no Approve, Claim, Run or Send control.

## Plain content and the optional envelope

Existing string fields remain valid without a rich companion. `body` remains a message's readable Markdown source, and plain text remains readable when no Markdown constructs are present. IDs, keys, titles, names, status labels, and routing selectors remain bounded plain strings. Rich formatting is optional for longer content, not a required capture form or project setting.

A future rich-capable command accepts the existing string plus its optional companion (`content` for `body`, `brief_content` for `brief`, or `content` beside an existing object's `text` or `body`). The command must advertise that exact companion in its closed schema. A client cannot add rich fields to any other command by guessing the name. Every existing field's smaller text limit and authority rules still apply.

`ContentV1` has these closed fields:

| Field | Type and rule |
|---|---|
| `schema_version` | Integer `1`. Unsupported versions are refused for new writes. |
| `blocks` | Ordered array of 1–32 closed content blocks. Block IDs are unique within the envelope. |

Every block has `block_id` (a nonempty ASCII identifier of at most 64 bytes), `type`, and `fallback` (a UTF-8 Markdown string). The containing plain string must equal the block fallbacks joined in order with exactly two LF bytes (`\n\n`). The service compares exact bytes and refuses `CONTENT_FALLBACK_MISMATCH` before writing. This rule gives every rich message one deterministic, complete plain representation. No companion changes the fallback of an earlier message.

Fallbacks carry the material facts, labels, units, links, and media descriptions needed to understand the message. A chart needs its values or a readable data table. HTML needs a textual equivalent. A generic “see chart” is insufficient. The service can check byte identity and typed data bounds; it cannot prove that an author's prose accurately describes arbitrary HTML. Review and evidence checks therefore use the stored source and exact referenced artifacts, not visual appearance alone.

An absent envelope preserves current string semantics. An empty or malformed envelope is an input error, not a request to replace the string with blank content. A plain client sends and receives the string without negotiating rich support. A rich client checks service and renderer capabilities before adding the companion. Failure to render the companion always leaves the string available.

## Version 1 blocks

The following fields are added to the common `block_id,type,fallback` fields. Unknown fields or invalid combinations fail new writes. All numerical values must be finite and exactly representable within the canonical JSON number contract. Object IDs and hashes resolve through existing service authorization; they are not local paths.

| `type` | Additional closed fields | Meaning and bounds |
|---|---|---|
| `markdown` | None | Render `fallback` with the bounded shared Markdown parser. HTML stays literal. |
| `table` | `columns`, `rows`; optional `caption` | `columns` contains 1–20 distinct `{id,label}` strings. Each row has exactly one string cell per column, in column order. At most 200 rows and 2,000 UTF-8 bytes per cell, within the total payload bound. Cells contain text, not HTML or formula execution. Fallback includes all headers and cells. |
| `chart` | `chart_kind,x_label,y_label,series`; optional `x_unit,y_unit,caption` | `chart_kind=bar|line|scatter`. Each series is `{label,points:[{x,y}]}`. Bar `x` is text; line/scatter `x` is a finite number. `y` is a finite number. At most 20 series and 1,000 points total. Fallback contains all plotted values and units. No executable chart specification or remote dataset. |
| `html` | `html,css` | Static bounded semantic HTML and a bounded CSS subset under the rules below. Raw markup is never inferred from a Markdown block. |
| `media` | `attachment_ref,media_kind`; optional `caption` | `attachment_ref={attachment_id,sha256,representation}` with `representation=original|preview`. `media_kind=image|video|audio|pdf|text|file` is a hint, not type authority. The service and shared preview layer determine the actual format and availability. |

Default v1 limits are 65,536 UTF-8 bytes for a message fallback and 262,144 bytes for the complete canonical message text plus content envelope. Smaller field limits take precedence. Media bytes are separate managed attachments and never embedded as base64, data URLs, HTML assets, or chart data files. HTML has at most 65,536 bytes of markup and 16,384 bytes of CSS per block, with at most 2,000 parsed nodes, 32 levels of nesting, and 128 CSS rules across one message. Shared table/chart totals apply across the message, not separately to each block. Larger content uses existing managed attachments and explicit previews.

For example, this planned rich message uses a typed chart and a complete readable fallback. UUIDs are synthetic.

```json
{
	"project_id": "10000000-0000-4000-8000-000000000001",
	"command_id": "10000000-0000-4000-8000-000000000002",
	"task_id": "10000000-0000-4000-8000-000000000003",
	"body": "Frame time (ms): before 24; after 16. Target: at most 20 ms.",
	"content": {
		"schema_version": 1,
		"blocks": [{
			"block_id": "frame-time",
			"type": "chart",
			"fallback": "Frame time (ms): before 24; after 16. Target: at most 20 ms.",
			"chart_kind": "bar",
			"x_label": "Build",
			"y_label": "Frame time",
			"y_unit": "ms",
			"series": [{"label": "Measured", "points": [{"x": "before", "y": 24}, {"x": "after", "y": 16}]}],
			"caption": "Target: at most 20 ms."
		}]
	}
}
```

The example describes reported measurements. It does not create a recorded check, pass a budget, or prove which build was measured. Existing measured evidence retains its source, producer, exact target, and hash.

## Static HTML and CSS bounds

Version 1 permits declarative formatting that plain Markdown cannot express, including a compact comparison or labeled chart layout. It permits no script, event handler, active form, app bridge, plugin code, or arbitrary web page. The shared renderer parses the source into its allowlisted document model before display. It does not execute the original HTML.

Allowed elements are `section,div,span,p,h1,h2,h3,h4,h5,h6,ul,ol,li,blockquote,pre,code,strong,em,b,i,u,s,br,hr,figure,figcaption,table,caption,thead,tbody,tfoot,tr,th,td,a`. Allowed attributes are local `class`, `lang`, `dir`, `aria-label`, table `colspan` and `rowspan` (1–20), and `href` on links. The renderer owns the outer accessibility structure and does not accept author-supplied roles that hide text or impersonate controls. IDs and selectors cannot refer outside the block. Comments, processing instructions, custom elements, and unsupported attributes are rejected for new writes.

The CSS property allowlist is `color,background-color,font-weight,font-style,font-size,line-height,text-align,text-decoration,white-space,overflow-wrap,border,border-color,border-style,border-width,padding,margin,width,max-width,display,gap,flex-direction,flex-wrap,align-items,justify-content,grid-template-columns`, plus the four side-specific `padding-*` and `margin-*` properties. Color values are hexadecimal literals, `transparent`, or `currentColor`. Sizes use bounded `px`, `rem`, or percentages. Grid tracks use bounded lengths or `fr` values, or `repeat(n,minmax(0,1fr))` with integer `n` from 1 to 20. Other functions, including `calc()`, are refused. The renderer clamps font size to 0.75–3 rem, line height to 1–2.5, margins/padding/gap to 0–4 rem, and layout width to the content container. Grid columns number at most 20. CSS selectors name allowlisted tags or local classes, with at most four descendant steps. No global app stylesheet is accessible.

Disallowed constructs include `script`, SVG/XML, `iframe`, `object`, `embed`, forms/inputs/buttons, `img`/video/audio sources, inline event attributes, JavaScript URLs, `file:`/`data:`/custom schemes, `url()`, imports, fonts, generated content, fixed/absolute/sticky positioning, z-index, animation, transitions, filters, transforms, and CSS custom properties. Images and playback use media blocks and authorized previews. Typed charts use the bundled chart renderer. Author CSS cannot cover native controls or escape the block.

Links permit explicit `https:` URLs and service-resolved scoped Checklist entity links. The app resolves internal links under current grants. External navigation requires a user click through the existing macOS opening flow. Parsing, layout, hover, and export perform no network fetch, filesystem read, native command, clipboard access, or model invocation. A WebKit adapter, if used, has scripts disabled, no message bridge, no persistent website data, and a deny-by-default resource/navigation policy. The adapter receives only the parsed safe representation and verified media copies supplied by the preview layer.

The validator returns a field/block path and reason for unsupported markup or limits without saving a partial message. If an imported historic payload or a later renderer cannot display a block, the app shows its fallback with **Rich view unavailable** and an escaped Source option. It preserves the accepted original bytes. It does not silently remove unsafe source, run it, or convert it into trusted content. Changed validator/renderer versions produce a new derived representation, never a rewrite of message history.

## Shared rendering and field mapping

One portable content parser/validator and one declarative presentation model feed the native adapters. Conversation rows, orchestrator messages, ticket detail, and Human Requests reuse those components. Reusable table and chart renderers receive typed data. Media blocks reuse the existing attachment reader, verified-copy preparation, and format-specific file preview adapters. Ticket logic, routing, and forms do not select decoders or interpret CSS.

| Surface | Default | Planned rich integration |
|---|---|---|
| Ticket or orchestrator message | Existing `body` string and Markdown | Optional `content`; same history, author, correction, and exact-recipient receipts. |
| Ticket brief / project brief / pinned decision body | Existing string and existing field limit | Explicit advertised companion on that field's authorized command. Does not change rule provenance or applicable direction handling. |
| Acceptance item / final report | Existing `text` or report string | Optional companion beside that existing string. Stable requirement IDs, evidence mapping, and captured wording remain authoritative. |
| Human Request explanation / question prompt / manual-check instructions | Existing strings and native answer controls | Rich description only, with exact target labels and shared preview links. Choices, required values, revision checks, and Send answer remain native domain controls. |
| Attachment preview | Existing verified file and explicit format adapter | Reuse Markdown/table/media presentation helpers. Existing Markdown-file HTML stays literal; loading a file cannot opt it into the rich HTML block contract. |

Rich support is implemented field by field. No phase enables it on every field automatically. Source/Rendered selection, Copy plain text, and accessible fallback remain available. Copy and context export state whether they contain the original source or rendered plain representation. No rich content creates a substitute Approve, Claim, Run, or Send button.

Tables expose headers and cells in reading order, with keyboard access and a plain data view. Charts expose title, axes, units, legend, and the full data table. Media has meaningful fallback/alt text and a caption, with current original/preview availability. Video and audio start paused. Native file size, codec, pixel, page, and decode-worker limits continue to apply. The effective bound is the smaller applicable content or preview limit.

Color is supplementary. High contrast, Dynamic Type/large text, reduced motion, keyboard focus, and VoiceOver use the same semantic content. Wide tables scroll inside their block without making the message composer or native answer controls unreachable. A failed or canceled decode shows its exact unavailable/canceled state. Retained thumbnails remain context when an original is cleaned and cannot enable inspection or approval.

## Durable source, export, and evidence

The service stores the accepted plain string and rich envelope together with their schema version, stable block IDs/order, author/origin, and message or containing-field revision. The service computes a content digest over its canonical serialization of both values and returns it. Original UTF-8 text, HTML/CSS source, typed data, caption/fallback, and exact attachment IDs/hashes remain recoverable. Derived safe models, raster previews, layout caches, and accessibility trees are disposable and versioned by renderer/capability, not authoritative record content.

New record fields and conversation attachment ownership must enter the canonical storage/export/backup inventory before activation. An orchestrator conversation cannot borrow a fake ticket or an unrelated taskless-media capability to attach bytes. Its future same-project owner anchor and references must reuse the managed-object importer, hold/deletion gate, authorized reader lease, and capture registry. Until that ownership exists, media blocks can reference only attachments the containing surface is already authorized to reference and retain. A cross-ticket context link alone is insufficient.

Export/backup preserves both fallback and accepted envelope, all referenced immutable revisions, content digest, source attribution, correction trail, and attachment availability/retention metadata. It includes permitted retained original bytes through the normal capture inventory. Export does not flatten tables/charts to screenshots, silently drop unsupported versions, or replace missing originals with thumbnails. Existing owner-request/private-data/export policies still apply. Operational credentials, live endpoints, reply/routing tokens, and reusable grants remain outside exported metadata. Authored text is not silently redacted or rewritten.

Import/restore preserves supported or opaque historic envelopes losslessly, with plain fallback available even when rich rendering is unsupported. Import is not execution or native identity verification. Imported routes, participant generations, claims, and grants remain quarantined under the existing restore contract. Unknown versions cannot become new executable/active content through re-export or later rendering.

When content is evidence, the immutable manifest binds the accepted source digest and exact referenced artifact hashes. A correction is a new attributed record with its own digest and original reference. It cannot replace old evidence or carry an approval onto changed media. A screenshot of the rendered view is a separate artifact with its producer, renderer/app build, target digest, and limits. Render success, a chart threshold, or a media preview cannot mint a check result, inspected-image record, trusted owner answer, gate verdict, or completion.

## Bounded implementation and qualification

1. **Strings and durable envelope.** Preserve all existing plain clients and field limits. Add closed v1 validation, deterministic fallback comparison, exact canonical storage/digests, idempotent writes/corrections, lossless export/backup, and plain fallback for unsupported historic versions without rich execution. Prove Unicode/escaping, malformed input, oversize refusal, missing refs, cross-project denial, and changed hashes before native rendering.
2. **Reusable native renderers.** Add Markdown/table/chart and static HTML/CSS adapters behind explicit capabilities. Prove script/event/URL/resource/stylesheet rejection, parser/layout limits, no implicit network/filesystem/bridge access, readable fallback, Source/Copy, keyboard/large-text/high-contrast behavior, and a bounded long conversation. Rich-render failure must leave the message and composer usable.
3. **Field and media composition.** Add each advertised field companion, Human Request description rendering, orchestrator conversation ownership, and existing verified media previews. Prove draft/revision preservation, target replacement, original cleanup/unavailability, canceled copy/decode, paused playback, and no workflow side effect from view/open/copy.
4. **Exact installed evidence.** Qualify supported native renderers and provider transports separately. A text-only provider receives the plain fallback; the native app can still render the stored envelope. Rich rendering requires no new provider runtime. Record app/plugin/renderer versions, exact source/artifact hashes, accessibility observations, and actual delivery/acknowledgment separately.

These phases are planned work. This document authorizes no install, enrollment, subscription, live write, external send, provider launch, or recurring check. Current server discovery and [implementation status](implementation-status.md) remain the source of available behavior.
