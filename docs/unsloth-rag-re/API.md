# Unsloth Studio RAG — HTTP + tool API

Base: `http://127.0.0.1:8888/api/rag`  
Auth: Studio Bearer (same as other `/api/*`). Single-tenant: subject gates
access, not row-level tenancy.

Router: `studio/backend/routes/rag.py`  
Client: `studio/frontend/src/features/rag/api/rag-api.ts`

If sqlite-vec failed to load: `GET /knowledge-bases` → 200
`{ knowledgeBases: [], ragAvailable: false, ragUnavailableReason }`. All other
routes → **503** `"RAG is unavailable: the sqlite-vec extension could not be loaded."`

## Routes

| Method | Path | Body / query | Response |
|---|---|---|---|
| GET | `/knowledge-bases` | — | `{ knowledgeBases, ragAvailable? }` |
| POST | `/knowledge-bases` | `{ name, description? }` | `{ id, name }` |
| PATCH | `/knowledge-bases/{kb_id}` | `{ name?, description? }` | `{ ok }` |
| DELETE | `/knowledge-bases/{kb_id}` | — | `{ ok }` |
| GET | `/knowledge-bases/{kb_id}/documents` | — | `{ documents: RagDocument[] }` |
| POST | `/knowledge-bases/{kb_id}/documents` | multipart `file` or `nativePathLease`; optional `ocr`, `caption` | `{ documentId, jobId, filename }` |
| POST | `/knowledge-bases/{kb_id}/linked-folders` | `{ nativePathLease, displayName }` | `{ linkedFolder, job }` |
| GET | `/threads/{thread_id}/documents` | — | `{ documents }` |
| POST | `/threads/{thread_id}/documents` | same multipart | `{ documentId, jobId, filename }` |
| GET | `/projects/{project_id}/documents` | — | `{ documents }` |
| POST | `/projects/{project_id}/documents` | same multipart | `{ documentId, jobId, filename }` |
| POST | `/projects/{project_id}/linked-folders` | `{ nativePathLease, displayName }` | `{ linkedFolder, job }` |
| GET | `/linked-folders` | `?scope_type=&scope_id=` | `{ linkedFolders }` |
| PATCH | `/linked-folders/{folder_id}` | displayName / autoSync | folder |
| DELETE | `/linked-folders/{folder_id}` | `?remove_index=` | `{ ok }` |
| POST | `/linked-folders/{folder_id}/sync` | — | `{ job }` |
| POST | `/linked-folders/{folder_id}/rebuild` | — | `{ job }` |
| GET | `/documents` | — | `{ documents }` (global Data tab) |
| DELETE | `/documents/{document_id}` | — | `{ ok }` |
| GET | `/jobs/{job_id}` | — | `IndexJob` |
| GET | `/jobs/{job_id}/events` | SSE | `progress` / `complete` / `error` then `[DONE]` |
| GET | `/linked-folder-jobs/{job_id}` | — | `FolderSyncJob` |
| GET | `/linked-folder-jobs/{job_id}/events` | SSE | same |
| POST | `/search` | see below | `{ results: [...] }` |
| GET | `/documents/{id}/preview-target` | `?chunk_id=` | `PreviewTarget` |
| GET | `/documents/{id}/file-url` | — | `{ url }` signed path |
| GET | `/documents/{id}/file-signed` | `?token=` (no Bearer) | file bytes (Range OK) |

There is **no** public `/api/rag/search_knowledge_base`. The LLM tool hits the
Python function, not a separate HTTP verb. `/search` is the UI/debug twin.

## POST `/search`

```json
{
  "query": "worktree isolation",
  "kb_id": null,
  "thread_id": "__LOCALID_6JuFlsb",
  "project_id": "312d83a1-4df3-4da4-b45a-bc907a6e7588",
  "top_k": 10,
  "min_score": 0.0,
  "mode": "hybrid"
}
```

`mode`: `hybrid` | `lexical` | `dense`. Need at least one of `kb_id`,
`project_id`, `thread_id`. `top_k` 1…50, default 10.

```json
{
  "results": [
    {
      "chunkId": "…",
      "documentId": "…",
      "filename": "ARCHITECTURE.md",
      "page": null,
      "score": 0.0312,
      "text": "…"
    }
  ]
}
```

Hybrid `score` is **RRF**, not cosine. Cosine is internal (`dense_score`) for
the auto-inject floor.

## Tool `search_knowledge_base`

Registered in `core/inference/tools.py` (`ALL_TOOLS`). Always-safe.

```json
{
  "type": "function",
  "function": {
    "name": "search_knowledge_base",
    "description": "Search the user's uploaded documents and knowledge bases for relevant passages. Use this whenever the question may be answered by the attached documents, then cite the returned chunks.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Natural-language search query." },
        "top_k": { "type": "integer", "description": "Max chunks to return." }
      },
      "required": ["query"]
    }
  }
}
```

Scope is **not** a tool arg. The chat loop injects `rag_scope`
`{ kb_id?, thread_id?, project_id?, autoinject?, autoinject_min_score?, default_top_k? }`.

Tool result text (model-facing):

```xml
<chunk id="1" source="ARCHITECTURE.md">
passage
</chunk>
```

UI also gets a source-map list (`citationId`, `chunkId`, `documentId`,
`filename`, `page`, `text`, `score`).

Empty scope → `"No documents are attached to this chat."`  
No hits → `"No matching chunks were found in the knowledge base."`

## How chat gets context

1. **Tool call** (normal).
2. **`build_rag_autoinject`**: last user text → hybrid retrieve; inject only if
   max dense cosine ≥ 0.70 (default). Spliced as a synthetic tool-shaped event
   (`tool_name: search_knowledge_base`) so the model sees passages without
   choosing the tool.
3. **Whole-document**: thread attachments whose total tokens ≤ 6000, all chunks
   in order. Else retrieval.

No silent “stuff the entire KB into the system prompt.”

## Example (no secrets)

Upload to a thread (browser / Studio session cookie or Bearer):

```http
POST /api/rag/threads/__LOCALID_6JuFlsb/documents
Content-Type: multipart/form-data

file=@notes.pdf
ocr=true
caption=true
```

```json
{ "documentId": "e25612d6-…", "jobId": "…", "filename": "notes.pdf" }
```

Then poll `GET /api/rag/jobs/{jobId}` until `status=completed`.
