from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import List, Dict
import logging
import uuid
from datetime import datetime, timezone
from kubernetes import client as k8s_client, config as k8s_config
from kubernetes.client.rest import ApiException

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
                "namespace": ns.metadata.name,
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

class DeployRequest(BaseModel):
    app_name: str
    image: str
    revision: str

class PromoteRequest(BaseModel):
    app_name: str

class RollbackRequest(BaseModel):
    app_name: str


def _get_team_namespace(team_id: str) -> str:
    if team_id not in teams_store:
        raise HTTPException(status_code=404, detail="Team not found")
    namespace = teams_store[team_id].get("namespace")
    if not namespace:
        # The operator may have created the namespace after this API pod started.
        # Do a live Kubernetes lookup and cache the result so subsequent calls are fast.
        try:
            v1 = k8s_client.CoreV1Api()
            ns_list = v1.list_namespace(
                label_selector=(
                    f"app.kubernetes.io/managed-by=teams-operator,"
                    f"teams.example.com/team-id={team_id}"
                )
            )
            if ns_list.items:
                namespace = ns_list.items[0].metadata.name
                teams_store[team_id]["namespace"] = namespace
                logger.info("Resolved namespace '%s' for team %s via live lookup", namespace, team_id)
        except Exception as exc:
            logger.warning("Live namespace lookup failed for team %s: %s", team_id, exc)
    if not namespace:
        raise HTTPException(
            status_code=409,
            detail="Team namespace not yet provisioned — wait for the operator to reconcile",
        )
    return namespace


def _build_rollout(app_name: str, image: str, revision: str, namespace: str) -> dict:
    full_image = f"{image}:{revision}"
    return {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "Rollout",
        "metadata": {
            "name": app_name,
            "namespace": namespace,
            "labels": {
                "app": app_name,
                "app.kubernetes.io/managed-by": "teams-api",
            },
            "annotations": {
                "commit-sha": revision,
            },
        },
        "spec": {
            "replicas": 1,
            "selector": {"matchLabels": {"app": app_name}},
            "template": {
                "metadata": {"labels": {"app": app_name}},
                "spec": {
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 1001,
                        "runAsGroup": 1001,
                        "fsGroup": 1001,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [
                        {
                            "name": app_name,
                            "image": full_image,
                            "imagePullPolicy": "IfNotPresent",
                            "ports": [{"containerPort": 8000}],
                            "securityContext": {
                                "runAsNonRoot": True,
                                "runAsUser": 1001,
                                "runAsGroup": 1001,
                                "allowPrivilegeEscalation": False,
                                "readOnlyRootFilesystem": False,
                                "capabilities": {"drop": ["ALL"]},
                                "seccompProfile": {"type": "RuntimeDefault"},
                            },
                            "resources": {
                                "requests": {"memory": "64Mi", "cpu": "50m"},
                                "limits": {"memory": "128Mi", "cpu": "100m"},
                            },
                            "livenessProbe": {
                                "httpGet": {"path": "/health", "port": 8000},
                                "initialDelaySeconds": 30,
                                "periodSeconds": 10,
                            },
                            "readinessProbe": {
                                "httpGet": {"path": "/health", "port": 8000},
                                "initialDelaySeconds": 5,
                                "periodSeconds": 5,
                            },
                        }
                    ],
                },
            },
            "strategy": {
                "blueGreen": {
                    "activeService": f"{app_name}-active",
                    "previewService": f"{app_name}-preview",
                    "autoPromotionEnabled": False,
                }
            },
        },
    }


def _build_service(app_name: str, namespace: str, role: str) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": {
            "name": f"{app_name}-{role}",
            "namespace": namespace,
            "labels": {
                "app": app_name,
                "app.kubernetes.io/managed-by": "teams-api",
            },
        },
        "spec": {
            "selector": {"app": app_name},
            "ports": [{"protocol": "TCP", "port": 8000, "targetPort": 8000}],
            "type": "ClusterIP",
        },
    }

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


@app.post("/teams/{team_id}/deploy")
async def deploy_app(team_id: str, req: DeployRequest):
    """Create or update an Argo Rollout + Services for an app in the team namespace."""
    namespace = _get_team_namespace(team_id)
    core = k8s_client.CoreV1Api()
    custom = k8s_client.CustomObjectsApi()

    for role in ("active", "preview"):
        svc_body = _build_service(req.app_name, namespace, role)
        svc_name = f"{req.app_name}-{role}"
        try:
            core.patch_namespaced_service(svc_name, namespace, svc_body)
        except ApiException as e:
            if e.status == 404:
                core.create_namespaced_service(namespace, svc_body)
            else:
                raise HTTPException(status_code=500, detail=f"Failed to apply service {svc_name}: {e.reason}")

    rollout_body = _build_rollout(req.app_name, req.image, req.revision, namespace)
    try:
        custom.patch_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace=namespace,
            plural="rollouts",
            name=req.app_name,
            body=rollout_body,
        )
    except ApiException as e:
        if e.status == 404:
            custom.create_namespaced_custom_object(
                group="argoproj.io",
                version="v1alpha1",
                namespace=namespace,
                plural="rollouts",
                body=rollout_body,
            )
        else:
            raise HTTPException(status_code=500, detail=f"Failed to apply rollout: {e.reason}")

    return {"message": f"Deploying {req.app_name} → {req.image} in namespace {namespace}"}


@app.post("/teams/{team_id}/promote")
async def promote_app(team_id: str, req: PromoteRequest):
    """Promote a paused blue/green Rollout — replicates `kubectl argo rollouts promote`.

    The kubectl plugin issues a small merge-patch on the `/status` subresource
    that clears `pauseConditions`. Once that condition is gone the controller
    resolves `controllerPause` itself and proceeds with the cutover.

    See: argoproj/argo-rollouts pkg/kubectl-argo-rollouts/cmd/promote/promote.go
    """
    namespace = _get_team_namespace(team_id)
    custom = k8s_client.CustomObjectsApi()
    status_patch = {"status": {"pauseConditions": None}}
    try:
        custom.patch_namespaced_custom_object_status(
            group="argoproj.io",
            version="v1alpha1",
            namespace=namespace,
            plural="rollouts",
            name=req.app_name,
            body=status_patch,
        )
    except ApiException as e:
        if e.status == 404:
            # Either the rollout doesn't exist, or this cluster's CRD doesn't
            # expose a status subresource. Fall back to the unified spec+status
            # merge patch on the main resource (Rollouts v0.9 behaviour).
            try:
                custom.patch_namespaced_custom_object(
                    group="argoproj.io",
                    version="v1alpha1",
                    namespace=namespace,
                    plural="rollouts",
                    name=req.app_name,
                    body={"spec": {"paused": False}, "status": {"pauseConditions": None}},
                )
            except ApiException as fallback_err:
                if fallback_err.status == 404:
                    raise HTTPException(
                        status_code=404,
                        detail=f"Rollout '{req.app_name}' not found in namespace {namespace}",
                    )
                raise HTTPException(
                    status_code=500,
                    detail=f"Failed to promote rollout: {fallback_err.reason}",
                )
        else:
            raise HTTPException(status_code=500, detail=f"Failed to promote rollout: {e.reason}")

    return {"message": f"Promoting {req.app_name} — switching active traffic to new version."}


@app.get("/teams/{team_id}/apps/{app_name}/status")
async def app_status(team_id: str, app_name: str):
    """Return the current Argo Rollout phase for an app in the team namespace."""
    namespace = _get_team_namespace(team_id)
    custom = k8s_client.CustomObjectsApi()
    try:
        obj = custom.get_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace=namespace,
            plural="rollouts",
            name=app_name,
        )
        phase = obj.get("status", {}).get("phase", "Unknown")
        revision = obj.get("metadata", {}).get("annotations", {}).get("commit-sha", "unknown")
        return {"app_name": app_name, "namespace": namespace, "phase": phase, "revision": revision}
    except ApiException as e:
        if e.status == 404:
            raise HTTPException(
                status_code=404,
                detail=f"Rollout '{app_name}' not found in namespace {namespace}",
            )
        raise HTTPException(status_code=500, detail=f"Failed to get rollout status: {e.reason}")


@app.post("/teams/{team_id}/rollback")
async def rollback_app(team_id: str, req: RollbackRequest):
    """Abort an in-progress Rollout, keeping the active version live."""
    namespace = _get_team_namespace(team_id)
    custom = k8s_client.CustomObjectsApi()
    try:
        custom.patch_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace=namespace,
            plural="rollouts",
            name=req.app_name,
            body={"metadata": {"annotations": {"rollout.argoproj.io/abort": "true"}}},
        )
    except ApiException as e:
        if e.status == 404:
            raise HTTPException(status_code=404, detail=f"Rollout '{req.app_name}' not found in namespace {namespace}")
        raise HTTPException(status_code=500, detail=f"Failed to abort rollout: {e.reason}")

    return {"message": f"Rolling back {req.app_name} — aborting rollout, active version remains live."}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
