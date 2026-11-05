// Library Entra POC on Azure Container Apps.
//
// Two-pass deployment (infra/azure/deploy.sh drives it):
//   deployApps=false  registry, managed identity, Container Apps environment
//   deployApps=true   mock CAS, Patron Record API (internal), Library Portal, notices job
//
// The migration phase is just parameters: portalAuthMode / patronApiAuthMode / jobAuthMode.
// Phase 0 (CAS + API key) needs no Entra configuration at all.
//
// Secrets are Container Apps secrets, passed in by deploy.sh. (An earlier version used
// Key Vault references; tenants whose policy forces Key Vault to private-only, such as
// some managed sandbox subscriptions, then need a VNet-integrated environment and a private
// endpoint instead. See docs/01-auth-upgrade-playbook.md, Common errors.)

targetScope = 'resourceGroup'

@description('Short lowercase prefix for resource names (max 12 characters).')
@maxLength(12)
param prefix string = 'libpoc'

param location string = resourceGroup().location

@secure()
param secretKeyBase string = ''
@secure()
param legacyApiKey string = ''
@secure()
param portalClientSecret string = ''
@secure()
param patronApiClientSecret string = ''
@secure()
param jobClientSecret string = ''

param deployApps bool = false
param deployMockCas bool = true
param imageTag string = 'latest'

@allowed(['cas', 'entra'])
param portalAuthMode string = 'cas'

@allowed(['legacy', 'both', 'entra'])
param patronApiAuthMode string = 'legacy'

@allowed(['legacy', 'entra'])
param jobAuthMode string = 'legacy'

param phaseLabel string = 'Phase 0 · CAS + API key'

// Entra values: may be empty in phase 0.
param tenantId string = ''
param portalClientId string = ''
param patronApiClientId string = ''
param jobClientId string = ''
param patronApiScopes string = ''
param finesAuthContext string = ''
param graphTimeZone string = 'Pacific Standard Time'
param demoAutoProvision bool = true

@description('Daily schedule for the overdue-notices job (UTC cron).')
param noticesCron string = '0 15 * * *'

var suffix = take(uniqueString(resourceGroup().id), 8)
var acrName = toLower('${prefix}acr${suffix}')
var portalName = '${prefix}-portal'
var patronApiName = '${prefix}-patron-api'
var casName = '${prefix}-mock-cas'
var jobName = '${prefix}-notices'
var notConfigured = 'not-configured'

var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// ---------------------------------------------------------------- platform

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-logs-${suffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-apps-id'
  location: location
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, roleAcrPull)
  scope: acr
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
  }
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// ---------------------------------------------------------------- apps

var envDomain = cae.properties.defaultDomain
var portalUrl = 'https://${portalName}.${envDomain}'
var casUrl = 'https://${casName}.${envDomain}'
// Internal ingress: reachable only from inside the environment.
var patronApiUrl = 'https://${patronApiName}.internal.${envDomain}'
var registries = [{ server: acr.properties.loginServer, identity: identity.id }]
var identities = { type: 'UserAssigned', userAssignedIdentities: { '${identity.id}': {} } }

func secret(name string, value string) object => { name: name, value: empty(value) ? 'not-configured' : value }

func orPlaceholder(value string) string => empty(value) ? 'not-configured' : value

resource mockCas 'Microsoft.App/containerApps@2024-03-01' = if (deployApps && deployMockCas) {
  name: casName
  location: location
  identity: identities
  dependsOn: [acrPull]
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: { external: true, targetPort: 8081 }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'mock-cas'
          image: '${acr.properties.loginServer}/mock-cas:${imageTag}'
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
        }
      ]
      // One replica: SSO sessions and tickets live in memory.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource patronApi 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: patronApiName
  location: location
  identity: identities
  dependsOn: [acrPull]
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: { external: false, targetPort: 3001 }
      registries: registries
      secrets: [
        secret('legacy-api-key', legacyApiKey)
        secret('patron-api-client-secret', patronApiClientSecret)
      ]
    }
    template: {
      containers: [
        {
          name: 'patron-api'
          image: '${acr.properties.loginServer}/patron-api:${imageTag}'
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'RAILS_ENV', value: 'production' }
            { name: 'AUTH_MODE', value: patronApiAuthMode }
            { name: 'LEGACY_API_KEY', secretRef: 'legacy-api-key' }
            { name: 'ENTRA_TENANT_ID', value: orPlaceholder(tenantId) }
            { name: 'ENTRA_CLIENT_ID', value: orPlaceholder(patronApiClientId) }
            { name: 'ENTRA_CLIENT_SECRET', secretRef: 'patron-api-client-secret' }
            { name: 'FINES_AUTH_CONTEXT', value: empty(finesAuthContext) ? 'none' : finesAuthContext }
            { name: 'GRAPH_TIME_ZONE', value: graphTimeZone }
            { name: 'DEMO_AUTO_PROVISION', value: string(demoAutoProvision) }
            // Lets EntraAuth use the managed identity as a federated credential if you
            // set ENTRA_USE_MANAGED_IDENTITY_FIC=true (see docs/02-api-integration-playbook.md).
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
          ]
          probes: [
            { type: 'Liveness', httpGet: { path: '/healthz', port: 3001 }, initialDelaySeconds: 10 }
          ]
        }
      ]
      // One replica: demo patron data and the OBO token cache are in memory.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource portal 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: portalName
  location: location
  identity: identities
  dependsOn: [acrPull]
  properties: {
    managedEnvironmentId: cae.id
    configuration: {
      ingress: { external: true, targetPort: 3000 }
      registries: registries
      secrets: [
        secret('portal-secret-key-base', secretKeyBase)
        secret('legacy-api-key', legacyApiKey)
        secret('portal-client-secret', portalClientSecret)
      ]
    }
    template: {
      containers: [
        {
          name: 'portal'
          image: '${acr.properties.loginServer}/portal:${imageTag}'
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'RAILS_ENV', value: 'production' }
            { name: 'SECRET_KEY_BASE', secretRef: 'portal-secret-key-base' }
            { name: 'AUTH_MODE', value: portalAuthMode }
            { name: 'MIGRATION_PHASE_LABEL', value: phaseLabel }
            { name: 'PORTAL_BASE_URL', value: portalUrl }
            { name: 'PATRON_API_URL', value: patronApiUrl }
            { name: 'PATRON_API_KEY', secretRef: 'legacy-api-key' }
            { name: 'PATRON_API_SCOPES', value: orPlaceholder(patronApiScopes) }
            { name: 'CAS_LOGIN_URL', value: '${casUrl}/cas/login' }
            { name: 'CAS_LOGOUT_URL', value: '${casUrl}/cas/logout' }
            { name: 'CAS_VALIDATE_URL', value: '${casUrl}/cas/p3/serviceValidate' }
            { name: 'ENTRA_TENANT_ID', value: orPlaceholder(tenantId) }
            { name: 'ENTRA_CLIENT_ID', value: orPlaceholder(portalClientId) }
            { name: 'ENTRA_CLIENT_SECRET', secretRef: 'portal-client-secret' }
          ]
          probes: [
            { type: 'Liveness', httpGet: { path: '/healthz', port: 3000 }, initialDelaySeconds: 10 }
          ]
        }
      ]
      // One replica: sessions use the in-memory cache store (use Redis to scale out).
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource noticesJob 'Microsoft.App/jobs@2024-03-01' = if (deployApps) {
  name: jobName
  location: location
  identity: identities
  dependsOn: [acrPull]
  properties: {
    environmentId: cae.id
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: 300
      replicaRetryLimit: 1
      scheduleTriggerConfig: { cronExpression: noticesCron, parallelism: 1, replicaCompletionCount: 1 }
      registries: registries
      secrets: [
        secret('legacy-api-key', legacyApiKey)
        secret('job-client-secret', jobClientSecret)
      ]
    }
    template: {
      containers: [
        {
          name: 'notices'
          image: '${acr.properties.loginServer}/patron-api:${imageTag}'
          command: ['bin/overdue_notices']
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          env: [
            { name: 'AUTH_MODE', value: jobAuthMode }
            { name: 'PATRON_API_URL', value: patronApiUrl }
            { name: 'LEGACY_API_KEY', secretRef: 'legacy-api-key' }
            { name: 'ENTRA_TENANT_ID', value: orPlaceholder(tenantId) }
            { name: 'JOB_CLIENT_ID', value: orPlaceholder(jobClientId) }
            { name: 'JOB_CLIENT_SECRET', secretRef: 'job-client-secret' }
            { name: 'PATRON_API_APP_SCOPE', value: empty(patronApiClientId) ? notConfigured : 'api://${patronApiClientId}/.default' }
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
          ]
        }
      ]
    }
  }
}

// ---------------------------------------------------------------- outputs

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output portalUrl string = portalUrl
output casUrl string = casUrl
output portalRedirectUri string = '${portalUrl}/auth/entra_id/callback'
output appsIdentityPrincipalId string = identity.properties.principalId
output appsIdentityClientId string = identity.properties.clientId
output noticesJobName string = jobName
