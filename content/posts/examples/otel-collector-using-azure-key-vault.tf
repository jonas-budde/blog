locals {
  resource_group_name = "rg-otel-test"
  location            = "germanywestcentral"
  tenant_id           = data.azurerm_client_config.this.tenant_id
  key_vault_name      = "kv-otel-test"
  key_vault_id        = azurerm_key_vault.this.id
  otel_collector = {
    namespace                  = "monitoring"
    service_account_name       = "otel-collector-service-account"
    secret_name                = "otel-collector-secret"
    secret_provider_class_name = "otel-collector-secret-provider-class"
  }
  cluster_oidc_issuer_url                = azurerm_kubernetes_cluster.this.oidc_issuer_url
  federated_identity_credential_audience = ["api://AzureADTokenExchange"]
}

# requirements for setup

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.34.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "aks-otel-test"
}

data "azurerm_client_config" "this" {}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
}

resource "azurerm_key_vault" "this" {
  resource_group_name       = azurerm_resource_group.this.name
  location                  = azurerm_resource_group.this.location
  name                      = local.key_vault_name
  sku_name                  = "standard"
  enable_rbac_authorization = true
  tenant_id                 = data.azurerm_client_config.this.tenant_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "aks-otel-test"
  resource_group_name = local.resource_group_name
  dns_prefix          = "k8s-dev-jonas"
  location            = local.location

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "10s"
  }

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D2_v2"
  }
  identity {
    type = "SystemAssigned"
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# start resources of blog post

resource "azurerm_user_assigned_identity" "this" {
  name                = "uai-otel-collector"
  resource_group_name = local.resource_group_name
  location            = local.location
}

resource "azurerm_role_assignment" "uai_secret_user_datadog_api_key" {
  principal_id         = azurerm_user_assigned_identity.this.principal_id
  scope                = "${local.key_vault_id}/secrets/datadog-api-key"
  role_definition_name = "Key Vault Secrets User"
}

resource "azurerm_federated_identity_credential" "this" {
  name                = "fic-otel-collector"
  resource_group_name = local.resource_group_name
  issuer              = local.cluster_oidc_issuer_url
  audience            = local.federated_identity_credential_audience
  parent_id           = azurerm_user_assigned_identity.this.id
  subject             = "system:serviceaccount:${local.otel_collector.namespace}:${local.otel_collector.service_account_name}"
}

resource "kubernetes_manifest" "secret_provider_class" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name = local.otel_collector.secret_provider_class_name
      namespace = local.otel_collector.namespace
    }
    spec = {
      provider = "azure"
      parameters = {
        usePodIdentity = "false"
        clientID       = azurerm_user_assigned_identity.this.client_id
        tenantId       = local.tenant_id
        keyvaultName   = local.key_vault_name
        objects        = <<-EOT
        array:
          - |
            objectName: datadog-api-key
            objectType: secret
            objectVersion: ""
        EOT
      }
      secretObjects = [
        {
          secretName = local.otel_collector.secret_name
          type       = "Opaque"
          data = [
            { key = "DATADOG_API_KEY", objectName = "datadog-api-key" }
          ]
        }
      ]
    }
  }
  depends_on = [
    azurerm_role_assignment.uai_secret_user_datadog_api_key,
    azurerm_federated_identity_credential.this
  ]
}

resource "helm_release" "this" {
  name            = "helm-release-otel-collector"
  repository      = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart           = "opentelemetry-collector"
  namespace       = local.otel_collector.namespace
  cleanup_on_fail = true
  set = [{
    name  = "serviceAccount.annotations.azure\\.workload\\.identity/client-id"
    value = azurerm_user_assigned_identity.this.client_id
    }, {
    name  = "podLabels.azure\\.workload\\.identity/use"
    type  = "string"
    value = "true"
    }, {
    name  = "extraVolumes[0].name"
    value = "secrets-store"
    }, {
    name  = "extraVolumes[0].csi.driver"
    value = "secrets-store.csi.k8s.io"
    }, {
    name  = "extraVolumes[0].csi.readOnly"
    value = true
    }, {
    name  = "extraVolumes[0].csi.volumeAttributes.secretProviderClass"
    value = local.otel_collector.secret_provider_class_name
    }, {
    name  = "extraVolumeMounts[0].name"
    value = "secrets-store"
    }, {
    name  = "extraVolumeMounts[0].mountPath"
    value = "/mnt/secrets-store"
    }, {
    name  = "extraVolumeMounts[0].readOnly"
    value = true
    }, {
    name  = "extraEnvsFrom[0].secretRef.name"
    value = local.otel_collector.secret_name
    }, {
    name  = "extraEnvsFrom[0].secretRef.optional"
    value = false
    },{
    name = "image.repository"
    value = "otel/opentelemetry-collector-contrib"
    },{
    name = "image.tag"
    value = "0.128.0"
    },{
    name = "mode"
    value = "daemonset"
    },{
    name = "serviceAccount.name"
    value = local.otel_collector.service_account_name
  }]
  depends_on = [
    kubernetes_manifest.secret_provider_class
  ]
}