import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Rollout Demo API")

VERSION = os.getenv("VERSION", "v1")
COLOR = os.getenv("COLOR", "blue")

# In-memory item store
items: dict[str, dict] = {}
_next_id = 1


class ItemRequest(BaseModel):
    name: str


@app.get("/")
def info():
    return {
        "service": "rollout-demo-api",
        "version": VERSION,
        "color": COLOR,
        "description": "Deployed via Argo Rollouts Blue/Green strategy",
    }


@app.get("/health")
def health():
    return {"status": "ok", "version": VERSION}


@app.get("/items")
def list_items():
    return {"items": list(items.values()), "version": VERSION}


@app.post("/items", status_code=201)
def create_item(request: ItemRequest):
    global _next_id
    if not request.name or not request.name.strip():
        raise HTTPException(status_code=400, detail="Item name must not be empty")
    item_id = str(_next_id)
    _next_id += 1
    item = {"id": item_id, "name": request.name.strip()}
    items[item_id] = item
    return item


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
