#!/usr/bin/env python3
"""
Teams Operator - Creates Kubernetes namespaces when teams are created in the Teams API
"""

import asyncio
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Set, Dict, Any
import aiohttp
from kubernetes import client, config
from kubernetes.client.rest import ApiException

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('teams-operator')

class TeamsOperator:
    def __init__(self):
        self.teams_api_url = os.getenv('TEAMS_API_URL', 'http://teams-api-service.teams-api.svc.cluster.local:4200')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '30'))  # seconds
        self.known_teams: Set[str] = set()
        self.team_namespaces: Dict[str, str] = {}
        
        # Initialize Kubernetes client
        try:
            # Try in-cluster config first (when running in pod)
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes config")
        except config.ConfigException:
            # Fall back to local kubeconfig (for development)
            config.load_kube_config()
            logger.info("Loaded local kubeconfig")
        
        self.k8s_core_v1 = client.CoreV1Api()
        self.k8s_rbac_v1 = client.RbacAuthorizationV1Api()
        self._seed_from_cluster()
        
    def _seed_from_cluster(self) -> None:
        """Seed known_teams and team_namespaces from namespaces already managed by this operator."""
        try:
            ns_list = self.k8s_core_v1.list_namespace(
                label_selector="app.kubernetes.io/managed-by=teams-operator"
            )
            for ns in ns_list.items:
                labels = ns.metadata.labels or {}
                team_id = labels.get("teams.example.com/team-id")
                if team_id:
                    self.known_teams.add(team_id)
                    self.team_namespaces[team_id] = ns.metadata.name
            logger.info(
                "Seeded %d teams from existing cluster namespaces",
                len(self.known_teams),
            )
        except ApiException as e:
            logger.error("Failed to seed state from cluster: %s", e)
        except Exception as e:
            logger.error("Unexpected error seeding from cluster: %s", e)

    def sanitize_namespace_name(self, team_name: str) -> str:
        """Convert team name to valid Kubernetes namespace name"""
        # Lowercase, replace spaces/special chars with hyphens, remove consecutive hyphens
        namespace = team_name.lower()
        namespace = ''.join(c if c.isalnum() else '-' for c in namespace)
        namespace = '-'.join(filter(None, namespace.split('-')))  # Remove consecutive hyphens
        
        # Ensure it starts and ends with alphanumeric
        namespace = namespace.strip('-')
        
        # Kubernetes namespace names must be <= 63 characters
        if len(namespace) > 63:
            namespace = namespace[:63].rstrip('-')
            
        # Add prefix to avoid conflicts
        namespace = f"team-{namespace}"
        
        return namespace
    
    async def fetch_teams(self) -> list:
        """Fetch current teams from the Teams API"""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{self.teams_api_url}/teams") as response:
                    if response.status == 200:
                        teams = await response.json()
                        logger.debug(f"Fetched {len(teams)} teams from API")
                        return teams
                    else:
                        logger.error(f"Failed to fetch teams: HTTP {response.status}")
                        return []
        except aiohttp.ClientError as e:
            logger.error(f"Error connecting to Teams API: {e}")
            return []
        except Exception as e:
            logger.error(f"Unexpected error fetching teams: {e}")
            return []
    
    def create_namespace(self, team_id: str, team_name: str, namespace_name: str) -> bool:
        """Create a Kubernetes namespace for the team"""
        try:
            created_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

            # Define namespace metadata
            namespace_body = client.V1Namespace(
                metadata=client.V1ObjectMeta(
                    name=namespace_name,
                    labels={
                        # Required by Gatekeeper K8sRequiredLabels constraint
                        "admission": "true",
                        # Operator lifecycle labels
                        "app.kubernetes.io/managed-by": "teams-operator",
                        "teams.example.com/created-by": "teams-operator",
                        "teams.example.com/team-id": team_id,
                        "teams.example.com/team-name": team_name.replace(" ", "-").lower()
                    },
                    annotations={
                        "teams.example.com/original-team-name": team_name,
                        "teams.example.com/created-by": "teams-operator",
                        "teams.example.com/team-id": team_id,
                        # ISO 8601 timestamp — colons are not valid in label values
                        "teams.example.com/created-at": created_at
                    }
                )
            )
            
            # Create the namespace
            self.k8s_core_v1.create_namespace(body=namespace_body)
            logger.info(f"✅ Created namespace '{namespace_name}' for team '{team_name}' (ID: {team_id}) at {created_at}")

            # Stamp RBAC so only IDP components can create/update Rollouts in this namespace
            self._create_idp_rbac(namespace_name)

            return True
            
        except ApiException as e:
            if e.status == 409:  # Namespace already exists
                logger.warning(f"⚠️ Namespace '{namespace_name}' already exists")
                return True
            else:
                logger.error(f"❌ Failed to create namespace '{namespace_name}': {e}")
                return False
        except Exception as e:
            logger.error(f"❌ Unexpected error creating namespace: {e}")
            return False

    def _create_idp_rbac(self, namespace_name: str) -> None:
        """Create the idp-creator Role and RoleBinding in the given namespace.

        These restrict Deployment and Rollout write operations to the teams-api
        and teams-operator service accounts, providing defence-in-depth alongside
        the Gatekeeper RequireIDPOrigin admission policy.
        """
        role_body = client.V1Role(
            metadata=client.V1ObjectMeta(
                name="idp-creator",
                namespace=namespace_name,
                labels={"app.kubernetes.io/managed-by": "teams-operator"},
            ),
            rules=[
                client.V1PolicyRule(
                    api_groups=["apps"],
                    resources=["deployments"],
                    verbs=["create", "update", "patch", "delete"],
                ),
                client.V1PolicyRule(
                    api_groups=["argoproj.io"],
                    resources=["rollouts"],
                    verbs=["create", "update", "patch", "delete"],
                ),
            ],
        )
        binding_body = client.V1RoleBinding(
            metadata=client.V1ObjectMeta(
                name="idp-creator-binding",
                namespace=namespace_name,
                labels={"app.kubernetes.io/managed-by": "teams-operator"},
            ),
            role_ref=client.V1RoleRef(
                api_group="rbac.authorization.k8s.io",
                kind="Role",
                name="idp-creator",
            ),
            subjects=[
                client.V1Subject(kind="ServiceAccount", name="teams-api", namespace="teams-api"),
                client.V1Subject(kind="ServiceAccount", name="teams-operator", namespace="engineering-platform"),
            ],
        )
        for obj, create_fn in [
            (role_body, lambda: self.k8s_rbac_v1.create_namespaced_role(namespace_name, role_body)),
            (binding_body, lambda: self.k8s_rbac_v1.create_namespaced_role_binding(namespace_name, binding_body)),
        ]:
            try:
                create_fn()
                kind = obj.kind if hasattr(obj, "kind") and obj.kind else type(obj).__name__
                logger.info("✅ Created %s in namespace '%s'", kind, namespace_name)
            except ApiException as e:
                if e.status == 409:
                    kind = type(obj).__name__
                    logger.info("ℹ️  %s already exists in '%s', skipping", kind, namespace_name)
                else:
                    logger.error("❌ Failed to create RBAC in '%s': %s", namespace_name, e)
    
    def delete_namespace(self, namespace_name: str, team_name: str) -> bool:
        """Delete a Kubernetes namespace when team is removed"""
        try:
            self.k8s_core_v1.delete_namespace(name=namespace_name)
            logger.info(f"🗑️ Deleted namespace '{namespace_name}' for removed team '{team_name}'")
            return True
        except ApiException as e:
            if e.status == 404:  # Namespace doesn't exist
                logger.warning(f"⚠️ Namespace '{namespace_name}' not found (already deleted?)")
                return True
            else:
                logger.error(f"❌ Failed to delete namespace '{namespace_name}': {e}")
                return False
        except Exception as e:
            logger.error(f"❌ Unexpected error deleting namespace: {e}")
            return False
    
    async def reconcile_teams(self):
        """Main reconciliation loop - sync teams with namespaces"""
        teams = await self.fetch_teams()
        current_teams = {team['id']: team for team in teams}
        current_team_ids = set(current_teams.keys())
        
        # Handle new teams (create namespaces)
        new_teams = current_team_ids - self.known_teams
        for team_id in new_teams:
            team = current_teams[team_id]
            team_name = team['name']
            namespace_name = self.sanitize_namespace_name(team_name)
            
            if self.create_namespace(team_id, team_name, namespace_name):
                self.team_namespaces[team_id] = namespace_name
        
        # Handle deleted teams (remove namespaces)
        deleted_teams = self.known_teams - current_team_ids
        for team_id in deleted_teams:
            if team_id in self.team_namespaces:
                namespace_name = self.team_namespaces[team_id]
                # Get team name from namespace annotations if possible
                team_name = f"team-{team_id}"  # fallback
                
                if self.delete_namespace(namespace_name, team_name):
                    del self.team_namespaces[team_id]
        
        # Update known teams
        self.known_teams = current_team_ids
        
        if new_teams or deleted_teams:
            logger.info(f"📊 Reconciliation complete: {len(current_teams)} teams, {len(self.team_namespaces)} namespaces")
    
    async def run(self):
        """Main operator loop"""
        logger.info(f"🚀 Teams Operator starting...")
        logger.info(f"📡 Teams API URL: {self.teams_api_url}")
        logger.info(f"⏰ Poll interval: {self.poll_interval} seconds")
        
        # Initial reconciliation
        await self.reconcile_teams()
        
        # Main loop
        while True:
            try:
                await asyncio.sleep(self.poll_interval)
                await self.reconcile_teams()
            except KeyboardInterrupt:
                logger.info("👋 Received shutdown signal, exiting...")
                break
            except Exception as e:
                logger.error(f"❌ Error in main loop: {e}")
                await asyncio.sleep(self.poll_interval)

async def main():
    """Entry point"""
    operator = TeamsOperator()
    await operator.run()

if __name__ == "__main__":
    asyncio.run(main())
