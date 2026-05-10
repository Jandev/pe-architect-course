// src/environments/environment.prod.ts
export const environment = {
  production: true,
  apiUrl: "http://teams-api.127.0.0.1.sslip.io:30080",
  keycloak: {
    url: "http://platform-auth.127.0.0.1.sslip.io:30080",
    realm: "teams",
    clientId: "teams-ui",
  },
};
