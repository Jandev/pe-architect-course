import { Component, OnInit } from "@angular/core";
import { TeamsService } from "../../services/teams.service";
import {
  Team,
  DeployRequest,
  PromoteRequest,
  RollbackRequest,
} from "../../models/team.model";

interface DeployForm {
  appName: string;
  image: string;
  revision: string;
}

interface DeployStatus {
  loading: boolean;
  lastApp: string;
  error: string;
  success: string;
}

@Component({
  selector: "app-team-list",
  templateUrl: "./team-list.component.html",
  styleUrls: ["./team-list.component.css"],
})
export class TeamListComponent implements OnInit {
  teams: Team[] = [];
  isLoading = true;
  errorMessage = "";

  expandedDeploys = new Set<string>();
  deployForms: Record<string, DeployForm> = {};
  deployStatus: Record<string, DeployStatus> = {};

  constructor(private teamsService: TeamsService) {}

  ngOnInit() {
    this.loadTeams();
  }

  loadTeams() {
    this.isLoading = true;
    this.errorMessage = "";

    this.teamsService.getTeams().subscribe({
      next: (teams) => {
        this.teams = teams;
        this.isLoading = false;
      },
      error: (error) => {
        this.errorMessage = error;
        this.isLoading = false;
      },
    });
  }

  deleteTeam(teamId: string, teamName: string) {
    if (confirm(`Are you sure you want to delete team "${teamName}"?`)) {
      this.teamsService.deleteTeam(teamId).subscribe({
        next: () => {
          this.loadTeams();
        },
        error: (error) => {
          this.errorMessage = error;
        },
      });
    }
  }

  toggleDeploy(teamId: string) {
    if (this.expandedDeploys.has(teamId)) {
      this.expandedDeploys.delete(teamId);
    } else {
      this.expandedDeploys.add(teamId);
      if (!this.deployForms[teamId]) {
        this.deployForms[teamId] = { appName: "", image: "", revision: "" };
      }
      if (!this.deployStatus[teamId]) {
        this.deployStatus[teamId] = {
          loading: false,
          lastApp: "",
          error: "",
          success: "",
        };
      }
    }
  }

  onDeploy(teamId: string) {
    const form = this.deployForms[teamId];
    if (!form?.appName || !form?.image || !form?.revision) return;

    const status = this.deployStatus[teamId];
    status.loading = true;
    status.error = "";
    status.success = "";

    const req: DeployRequest = {
      app_name: form.appName,
      image: form.image,
      revision: form.revision,
    };
    this.teamsService.deployApp(teamId, req).subscribe({
      next: () => {
        status.loading = false;
        status.lastApp = form.appName;
        status.success = `Deployed ${form.appName} → ${form.image}:${form.revision}. Preview is spinning up.`;
      },
      error: (error) => {
        status.loading = false;
        status.error = error;
      },
    });
  }

  onPromote(teamId: string) {
    const status = this.deployStatus[teamId];
    if (!status?.lastApp) return;

    status.loading = true;
    status.error = "";
    status.success = "";

    const req: PromoteRequest = { app_name: status.lastApp };
    this.teamsService.promoteApp(teamId, req).subscribe({
      next: () => {
        status.loading = false;
        status.success = `Promoted ${status.lastApp} — active traffic now serving the new revision.`;
      },
      error: (error) => {
        status.loading = false;
        status.error = error;
      },
    });
  }

  onRollback(teamId: string) {
    const status = this.deployStatus[teamId];
    if (!status?.lastApp) return;

    status.loading = true;
    status.error = "";
    status.success = "";

    const req: RollbackRequest = { app_name: status.lastApp };
    this.teamsService.rollbackApp(teamId, req).subscribe({
      next: () => {
        status.loading = false;
        status.success = `Rolled back ${status.lastApp} — active version remains live.`;
        status.lastApp = "";
      },
      error: (error) => {
        status.loading = false;
        status.error = error;
      },
    });
  }

  formatDate(dateString: string): string {
    return new Date(dateString).toLocaleDateString("en-US", {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  }
}
