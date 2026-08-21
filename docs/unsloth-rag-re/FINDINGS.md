# Unsloth Studio RAG — findings

Ground truth: **Unsloth.app 0.1.800-beta** (`ai.unsloth.studio`), Python package
`studio` under `~/.unsloth/studio/unsloth_studio/lib/python3.13/site-packages/studio/`.
License on that tree: AGPL-3.0. Analyzed 2026-08-16. No live secrets copied.

Product docs call this **Chat with Files** (hybrid search, citations, PDF preview,
per-thread documents, `search_knowledge_base`, customizable embedding models).
Code matches those claims. It is **experimental in the sense of “extension must
load sqlite-vec”**: if vec fails, KB list returns 200 + `ragAvailable: false`;
every other `/api/rag` route is 503.

## Architecture

```
Tauri desktop (`unsloth-studio`)
        │  HTTP :8888  (Bearer)
        ▼
FastAPI `studio.backend`  prefix /api/rag
        │
        ├─ ingest: parsers → chunking → embeddings → store
        ├─ retrieve: FTS5 + sqlite-vec cosine → RRF
        └─ chat loop: tool + optional auto-inject / whole-doc
                │
                ▼
 ~/.unsloth/studio/rag/rag.db          (SQLite + FTS5 + sqlite-vec 0.1.9)
 ~/.unsloth/studio/rag/uploads/        (sha-named copies / linked-*.md)
 llama-server --embedding  (this Mac: unsloth/bge-small-en-v1.5-GGUF F16)
```

Layers:

| Piece | Where |
|---|---|
| UI | `studio/frontend/src/features/rag/` + `components/assistant-ui/rag-sources.tsx` |
| HTTP | `studio/backend/routes/rag.py` mounted at `/api/rag` (`main.py:1374`) |
| Engine | `studio/backend/core/rag/{ingestion,chunking,parsers,retrieval,tool,folder_sync,embeddings,embed_llama_server}.py` |
| DB | `studio/backend/storage/rag_db.py` → `rag_db_path()` = `~/.unsloth/studio/rag/rag.db` |

Chat inference (`core/inference/tools.py`) registers `search_knowledge_base` in
`ALL_TOOLS` and marks it `_ALWAYS_SAFE_TOOLS` (no sandbox prompt). Dispatch
lazy-imports `core.rag.tool`.

## Ingest

1. **Upload** (multipart `file` or Tauri `nativePathLease`) or **linked folder**
   scan. Accept: `.pdf .txt .md .markdown .docx .html .htm`. Cap
   `RAG_MAX_UPLOAD_BYTES` default **200 MB** (0 = off).
2. Bytes land in `uploads/` as `{uuid}.{ext}` or `linked-{uuid}.{ext}`.
   `documents.sha256` + `(scope, sha256)` index for dedup.
3. **Parse** (`parsers.py`): PDF via pymupdf4llm Markdown (`RAG_PDF_MARKDOWN=1`)
   else PyMuPDF; txt/md/docx/html → one page. Optional **OCR** (vision model,
   pages with `< RAG_OCR_MIN_CHARS` extractable text, max 20 pages) and
   **figure caption** tiles (vision, max 24 tiles / 4 figure pages).
4. **Chunk** (`chunking.py`): recursive separators
   (`\n# `, `\n## `, `\n### `, `\n\n`, `\n`, `. `, ` `, `""`) then greedy merge.
   Default **500 tokens**, **64 overlap** (`RAG_CHUNK_TOKENS` / `RAG_CHUNK_OVERLAP`).
   BGE-512 limit: keep ≤ embedder_max − ~12. Observed max `token_count` = **500**.
5. **Embed**: backend `RAG_EMBED_BACKEND=auto`. On this Mac all 270 docs tagged
   `llama-server:unsloth/bge-small-en-v1.5:unsloth/bge-small-en-v1.5-GGUF`.
   Vectors are **float[384]** cosine (`chunks_vec` sqlite-vec `vec0`).
6. Job row in `ingestion_jobs`; SSE `/api/rag/jobs/{id}/events`.

Linked folders (`folder_sync.py`): 30s reconcile, metadata compare, max
**10_000** files (`RAG_FOLDER_MAX_FILES`). This machine: one folder
`VibeCoder` → `/Users/maxkongerskov/VibeCoder` (268 files, 1397 chunks).

## Query

Scopes (`store.py`): `kb_{id}`, `project_{id}`, `thread_{id}`.

- Explicit **KB** is exclusive.
- Else **project + thread** combine (project chat also sees thread attachments).

Retrieval (`retrieval.py`):

| Mode | What |
|---|---|
| `lexical` | FTS5 porter unicode61, top **30** |
| `dense` | embed query, vec0 cosine, top **30** |
| `hybrid` (default) | both, fuse **RRF** `1/(60+rank)`, keep **10** |

`search_knowledge_base` formats hits as:

```xml
<chunk id="1" source="ARCHITECTURE.md" page="3">
…passage…
</chunk>
```

plus a parallel citation source-map (`citationId`, `chunkId`, `documentId`,
`filename`, `page`, `text`, `score`) for clickable UI.

**Whole-document** (`RAG_THREAD_WHOLE_DOC=1`, budget **6000** tokens): if a
*thread-attached* corpus fits, inject **every chunk in order** instead of top-K.
KB/project corpora never get whole-doc (search only). This DB: two thread
attachments of the same PDF at **1600 chunks** each — far over 6000 tokens, so
those threads fall back to retrieval.

**Auto-inject** (`build_rag_autoinject` in `tools.py`): pre-retrieve last user
turn; inject only if some hit’s dense cosine ≥ **0.70**
(`RAG_AUTOINJECT_MIN_SCORE`). Comment: small models (<~4B) often skip the tool,
so this forces consult.

Chat completions get RAG via **tool result** (primary) and **forced splice**
(auto-inject / whole-doc), not a silent system dump of the whole KB.

## Live corpus (this Mac, 2026-08-16)

| Table | Count |
|---|---|
| knowledge_bases | 0 |
| documents | 270 |
| chunks | 4597 (all `kind=text`) |
| linked_folders | 1 (`VibeCoder`, status `syncing`) |
| linked_folder_files | 268 |

Scopes: `project_312d83a1-…` (268 docs), two `thread___LOCALID_*` PDFs (1600
chunks each). Embedder identity as above. sqlite-vec **v0.1.9**.

## UI

- Project **Sources** panel + linked folder picker (desktop path lease).
- Per-thread file attach (chat drop / upload).
- Settings **Data** tab: global uploaded-files list.
- Citations: `rag-sources.tsx` + `PreviewTarget` (PDF page + 0–1 regions).
- PDF.js range GETs a **signed** `/file-signed?token=` URL (600s, process-local HMAC). HTML uploads served as `text/plain` (no same-origin script).
- Accept string: `RAG_UPLOAD_ACCEPT` = `.pdf,.txt,.md,.markdown,.docx,.html,.htm`.

Empty KB list on this machine: they use **project + thread**, not named KBs.

## Honesty

- Shipped and wired; gated on sqlite-vec.
- 200 MB / 10k-file caps; Reddit “6 GB of PDFs” is the product complaint — one
  177 MB PDF is already in `uploads/` twice (two thread copies).
- Switching embed backend **invalidates** dense space (`embedding_identity`);
  must rebuild.
- VibeCoder already walks the repo with `read_file` / `grep`. Do **not** clone
  that. What’s missing is a **document KB**: PDF/DOCX ingest, hybrid FTS+dense,
  citations, thread-vs-project scope, `search_knowledge_base`.

## Gap vs VibeCoder memory

| | Unsloth RAG | VibeCoder |
|---|---|---|
| Corpus | Uploaded + linked-folder docs | MEMORY.md / DECISIONS.md / session logs |
| Search | FTS5 + 384-d cosine + RRF | Keyword/FTS-style `MemoryIndex` only |
| Embeddings | bge-small (llama-server GGUF) | none |
| Citations / PDF preview | yes | no |
| Tool | `search_knowledge_base` | `memory` / `memory_search` / `memory_get` |
| Per-thread docs | yes (`thread_{id}`) | one-shot attach, not indexed |
| Whole-doc inject | thread files ≤ 6k tokens | n/a |
| Persist | sqlite + uploads | markdown files + JSON chunk index |

## Open questions

- Whether Studio exposes Hugging Face **search** as a RAG source (docs mention
  it; this tree’s ingest is local files only).
- Exact `RAG_AUTOINJECT` default when `rag_scope.autoinject` is omitted
  (`_autoinject_enabled()` not fully traced).
- Named KB UX: implemented, unused here.

See `API.md`, `STORAGE.md`.
