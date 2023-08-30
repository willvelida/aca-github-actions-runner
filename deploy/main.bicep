@description('Location to deploy the resources. Default is location of the resource group')
param location string = resourceGroup().location

@description('Suffix applied to the resources')
param appSuffix string = uniqueString(resourceGroup().id)

@description('The name of the Log Analytics workspace that will be deployed')
param logAnalyticsWorkspaceName string = 'law-${appSuffix}'

@description('The name of the Container App Environment that will be deployed')
param containerAppEnvName string = 'env-${appSuffix}'

@description('The name of the container registry that will be deployed')
param acrName string = 'acr${appSuffix}'

@description('The name of the Container App job')
param acaJobName string = 'github-runner'

@description('The Git Repository Url')
param gitRepositoryUrl string = 'https://github.com/Azure-Samples/container-apps-ci-cd-runner-tutorial.git'

@description('The name of the image that we will create')
param imageName string = 'github-actions-runner'

@description('The GitHub PAT token that will be used to authenticate')
param githubPATtoken string

@description('The owner of the repository in GitHub')
param repoOwner string = 'willvelida'

@description('The name of the repo in GitHub')
param repoName string = 'my-blog'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-06-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

module buildAcrImage 'br/public:deployment-scripts/build-acr:2.0.2' = {
  name: 'buildGHImage'
  params: {
    AcrName: acr.name
    gitRepositoryUrl: gitRepositoryUrl
    imageName: imageName
    imageTag: '1.0'
    gitBranch: 'main'
    acrBuildPlatform: 'linux'
    dockerfileName: 'Dockerfile.github'
  }
}

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource githubRunner 'Microsoft.App/jobs@2023-05-01' = {
  name: acaJobName
  location: location
  properties: {
    environmentId: containerAppEnv.id
    configuration: {
      replicaTimeout: 1800
      triggerType: 'Event'
      replicaRetryLimit: 1
      secrets: [
        {
          name: 'personal-access-token'
          value: githubPATtoken
        }
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
      registries: [
        {
          server: acr.properties.loginServer
          passwordSecretRef: 'acr-password'
          username: acr.listCredentials().username
        }
      ]
      eventTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
        scale: {
          minExecutions: 0
          maxExecutions: 10
          pollingInterval: 30
          rules: [
            {
              name: 'github-runner'
              type: 'github-runner'
              metadata: any({
                'github-runner': 'https://api.github.com'
                owner: repoOwner
                runnerScope: 'repo'
                repos: repoName
                targetWorkflowQueueLength: 1
              })
              auth: [
                {
                  secretRef: 'personal-access-token'
                  triggerParameter: 'github-runner'
                }
              ]
            }
          ]
        }
      }
    }
    template: {
      containers: [
        {
          image: buildAcrImage.outputs.acrImage
          name: acaJobName
          resources: {
            cpu: json('2.0')
            memory: '4Gi'
          }
          env: [
            {
              secretRef: 'personal-access-token'
              name: 'GITHUB_PAT'
            }
            {
              name: 'REPO_URL'
              value: 'https://github.com/${repoOwner}/${repoName}'
            }
            {
              name: 'REGISTRATION_TOKEN_API'
              value: 'https://api.github.com/repos/${repoOwner}/${repoName}/actions/runners/registration-token'
            }
          ]       
        }
      ]
    }
  }
}
