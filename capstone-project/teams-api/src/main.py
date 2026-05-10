from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Dict
import logging
import uuid
from datetime import datetime, timezone
from kubernetes import client as k8s_client, config as k8s_config

logger = logging.getLogger(__name__)

# In-memory storage – declared before lifespan so the startup hook can populate it
teams_store: Dict[str, Dict] = {}


def _seed_teams_from_cluster() -> None:
    """Populate teams_store from Kubernetes namespaces managed by teams-operator."""
    try:
        try:
            k8s_config.load_incluster_config()
        except k8s_config.ConfigException:
            k8s_config.load_kube_config()

        v1 = k8s_client.CoreV1Api()
        ns_list = v1.list_namespace(
            label_selector="app.kubernetes.io/managed-by=teams-operator"
        )
        seeded = 0
        for ns in ns_list.items:
            labels = ns.metadata.labels or {}
            annotations = ns.metadata.annotations or {}

            team_id = labels.get("teams.example.com/team-id")
            original_name = annotations.get("teams.example.com/original-team-name")
            created_at_str = annotations.get("teams.example.com/created-at")

            if not team_id or not original_name:
                logger.warning(
                    "Skipping namespace '%s': missing required labels/annotations",
                    ns.metadata.name,
                )
                continue

            if team_id in teams_store:
                continue  # already present (e.g. API restarted mid-session)

            try:
                created_at = (
                    datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                    if created_at_str
                    else datetime.now(timezone.utc)
                )
            except ValueError:
                created_at = datetime.now(timezone.utc)

            teams_store[team_id] = {
                "id": team_id,
                "name": original_name,
                "created_at": created_at,
            }
            seeded += 1

        logger.info("Seeded %d teams from cluster namespaces", seeded)

    except k8s_config.ConfigException:
        logger.warning(
            "No Kubernetes config available; skipping cluster seeding (running locally?)"
        )
    except Exception as exc:
        logger.warning("Failed to seed teams from cluster: %s", exc)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    _seed_teams_from_cluster()
    yield


app = FastAPI(
    title="Teams API",
    description="A simple API for team leads to create and manage teams",
    version="1.0.0",
    lifespan=lifespan,
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows all origins
    allow_credentials=True,
    allow_methods=["*"],  # Allows all methods
    allow_headers=["*"],  # Allows all headers
)

# Pydantic models
class TeamCreate(BaseModel):
    name: str

class Team(BaseModel):
    id: str
    name: str
    created_at: datetime

@app.get("/")
async def root():
    return {"message": "Teams API is running"}

@app.post("/teams", response_model=Team)
async def create_team(team: TeamCreate):
    """Create a new team"""
    # Check if team name already exists
    for existing_team in teams_store.values():
        if existing_team["name"].lower() == team.name.lower():
            raise HTTPException(status_code=400, detail="Team name already exists")

    # Generate unique ID and create team
    team_id = str(uuid.uuid4())
    new_team = {
        "id": team_id,
        "name": team.name,
        "created_at": datetime.now()
    }

    teams_store[team_id] = new_team
    return Team(**new_team)

@app.get("/teams", response_model=List[Team])
async def get_teams():
    """Get all teams"""
    return [Team(**team) for team in teams_store.values()]

@app.get("/teams/{team_id}", response_model=Team)
async def get_team(team_id: str):
    """Get a specific team by ID"""
    if team_id not in teams_store:
        raise HTTPException(status_code=404, detail="Team not found")

    return Team(**teams_store[team_id])

@app.delete("/teams/{team_id}")
async def delete_team(team_id: str):
    """Delete a team"""
    if team_id not in teams_store:
        raise HTTPException(status_code=404, detail="Team not found")

    deleted_team = teams_store.pop(team_id)
    return {"message": f"Team '{deleted_team['name']}' deleted successfully"}

@app.get("/health")
async def health_check():
    """Health check endpoint for Kubernetes"""
    return {"status": "healthy", "teams_count": len(teams_store)}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
