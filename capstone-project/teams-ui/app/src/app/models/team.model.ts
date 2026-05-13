// src/app/models/team.model.ts
export interface Team {
  id: string;
  name: string;
  created_at: string;
}

export interface TeamCreate {
  name: string;
}

export interface DeployRequest {
  app_name: string;
  image: string;
  revision: string;
}

export interface PromoteRequest {
  app_name: string;
}

export interface RollbackRequest {
  app_name: string;
}
