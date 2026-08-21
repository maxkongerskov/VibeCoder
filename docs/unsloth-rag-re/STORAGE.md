# Unsloth Studio RAG — storage

Root: `~/.unsloth/studio/rag/`  
Resolved by `studio/backend/utils/paths/storage_roots.py` → `rag_root()`.

```
~/.unsloth/studio/rag/
  rag.db          # SQLite + FTS5 + sqlite-vec (this machine ~33 MB)
  uploads/        # 270 files: uuid.ext or linked-{uuid}.ext
```

App Support `~/Library/Application Support/ai.unsloth.studio` is **not** the
RAG store (layout flag only). Projects live under
`~/Documents/Unsloth Studio/Projects/` and map to `documents.project_id` /
scope `project_{uuid}`.

## `rag.db`

WAL. Loads **sqlite-vec** (`CREATE_VERSION v0.1.9`). Schema created in
`storage/rag_db.py`.

### Application tables

**`knowledge_bases`**
- `id` TEXT PK, `name`, `description`, `embedding_model`, `created_at`
- Unused here (0 rows). Named KBs are optional.

**`documents`**
- `id`, `scope` (`kb_*` | `project_*` | `thread_*`), `kb_id`, `thread_id`,
  `project_id`
- `filename`, `sha256`, `status` (`pending|running|completed|failed`)
- `error`, `num_chunks`, `stored_path`, `created_at`
- `embedding_model` — **identity tag**, not just a repo name, e.g.
  `llama-server:unsloth/bge-small-en-v1.5:unsloth/bge-small-en-v1.5-GGUF`
- `linked_folder_id`, `linked_relative_path` for folder-sync rows
- Indexes: `scope`, `(scope, sha256)`, partial `linked_folder_id`

**`chunks`**
- `id`, `document_id`, `scope`, `chunk_index`, `text`
- `page_number`, `source_page_index`, `token_count`
- `kind` default `text` (all 4597 rows here)
- `pdf_regions_json` — highlight boxes for PDF preview

**`ingestion_jobs`**
- `id`, `document_id`, `scope`, `status`, `stage`, `progress`, `error`, `created_at`

**`rag_job_leases`**
- `(kind, job_id)` PK, `owner_id`, `expires_at` — multi-worker ingest lease

**`linked_folders`**
- `id`, `scope_type` (`knowledge_base|project`), `scope_id`, `scope`, `path`,
  `name`, `root_device`, `root_inode`, `delete_remove_index`, `auto_sync`,
  `status`, `last_error`, `last_scan_at`, `withheld_paths`, timestamps
- UNIQUE `(scope, path)`

**`linked_folder_files`**
- PK `(folder_id, relative_path)`; `size_bytes`, `mtime_ns`, `device`, `inode`,
  `document_id`, `content_hash`, `synced_at`

**`linked_folder_sync_jobs`**
- queue + history; unique active job per folder
  (`status IN pending,running`)

**`linked_folder_retired_scopes`**
- KB delete in progress; blocks new writes until purge

### Indexes

**`chunks_fts`** — FTS5 `tokenize='porter unicode61'`  
columns: `text`, `chunk_id UNINDEXED`, `scope UNINDEXED`

**`chunks_vec`** — `vec0(scope TEXT partition key, chunk_id TEXT, embedding float[384] distance_metric=cosine)`  
plus vec0 shadow tables (`chunks_vec_chunks`, `_rowids`, `_vector_chunks00`,
`_metadata*`, `_info`).

## `uploads/`

| Pattern | Meaning |
|---|---|
| `{32hex}.pdf` | Thread/chat upload (content-addressed-ish uuid name) |
| `linked-{32hex}.md` / `.txt` | Copy of a linked-folder file |

This machine: **250 md, 18 txt, 2 pdf**. One PDF ~177 MB stored twice (two
thread IDs). `documents.stored_path` points here; preview/file-signed reads it.

Linked folder **does not** keep the original tree as the only copy: ingest
writes a `linked-*` snapshot under `uploads/` so the index survives moves
until the next sync.

## Embedding

Default model `unsloth/bge-small-en-v1.5`, GGUF companion
`unsloth/bge-small-en-v1.5-GGUF` variant **F16** (`RAG_EMBED_GGUF_*`).

This Mac: `llama-server --embedding --pooling cls` sidecar (observed earlier on
`127.0.0.1:50831`). Dimension **384**. Identity string must match between
index-time and query-time or dense search is empty/wrong.

`RAG_EMBED_BACKEND=auto`: sentence-transformers if CUDA/ROCm GPU in-process,
else llama-server. Switching backends requires re-ingest.

## Chunk parameters (env)

| Env | Default |
|---|---|
| `RAG_CHUNK_TOKENS` | 500 |
| `RAG_CHUNK_OVERLAP` | 64 |
| `RAG_TOP_K_LEXICAL` | 30 |
| `RAG_TOP_K_DENSE` | 30 |
| `RAG_TOP_K_HYBRID` | 10 |
| `RAG_RRF_K` | 60 |
| `RAG_THREAD_WHOLE_DOC` | 1 (on) |
| `RAG_WHOLE_DOC_MAX_TOKENS` | 6000 |
| `RAG_MAX_UPLOAD_BYTES` | 200×1024×1024 |
| `RAG_FOLDER_MAX_FILES` | 10000 |
| `RAG_FOLDER_SYNC_INTERVAL_S` | 30 |

Observed `chunks.token_count`: min 4, avg ~362, max 500.

## Scope strings

| Scope | Example |
|---|---|
| Project | `project_312d83a1-4df3-4da4-b45a-bc907a6e7588` |
| Thread | `thread___LOCALID_6JuFlsb` |
| KB | `kb_{uuid}` (none here) |

## What is not stored

- No FAISS / Lance / separate vector files — vectors live in sqlite-vec blobs
  inside `rag.db`.
- No Hugging Face remote corpus — ingest is local files only.
- Chat transcripts are **not** in `rag.db` (chat history is a different store).
