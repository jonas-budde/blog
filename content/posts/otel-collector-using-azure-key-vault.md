---
date: 2025-06-27
showTableOfContents: true
title: "OTEL Collector with Secrets from Azure Key Vault"
type: "post"
---

![architecture](/media/otel-collector-using-azure-key-vault/otel-collector-secret.png)

I recently deployed a OTEL collector in a AKS to collector metrics, logs and traces.
As the OTEL collector forwards these data to other systems, we need credentials to connect to these systems.

I used the [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/usage) to read secrets from a Azure Key Vault.

## Define local values

This block defines all necessary local values to avoid repetition and improve maintainability. It includes names and IDs for Azure resources like the Key Vault, identity settings, and parameters for the OpenTelemetry (OTEL) Collector deployment. Using locals makes the code cleaner and easier to manage.


```terraform
locals {
  resource_group_name = "rg-otel-test"
  location            = "germanywestcentral"
  tenant_id           = "xyz"
  subscription_id     = "xyz" 
  key_vault_name      = "kv-otel-test"
  key_vault_id        = "xyz" use output of key vault object
  otel_collector = {
    namespace            = "monitoring"
    service_account_name = "otel-collector-service-account"
    secret_name          = "otel-collector-secret"
    secret_provider_class_name = "otel-collector-secret-provider-class"
    image_tag = "0.128.0"
  }
  cluster_oidc_issuer_url                = "xyz" # use output of aks object
  federated_identity_credential_audience = ["api://AzureADTokenExchange"]
}
```

## Configure AKS and Key Vault

Enabling `workload_identity_enabled` and `oidc_issuer_enabled` on the AKS cluster lets your Collector pods authenticate to Azure AD via federated identity, eliminating the need for long‐lived service principal credentials. The `key_vault_secrets_provider` block turns on automatic secret refresh (every 10 s) so your pods always see the latest Key Vault values. Finally, setting `enable_rbac_authorization = true` on the Key Vault lets you enforce Azure RBAC policies for secure, workload‐identity–based access.

```terraform
resource "azurerm_kubernetes_cluster" "this" {
  ...
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "10s"
  }
  ...
}

resource "azurerm_key_vault" "this" {
  ...
  enable_rbac_authorization = true
  tenant_id                 = local.tenant_id
  ...
}
```

## Identity

We create a User-Assigned Managed Identity to authenticate the OTEL Collector in Kubernetes with Azure. We assign it the Key Vault Secrets User role on specific secrets, then bind it to a Kubernetes service account via a federated identity credential for workload identity (OIDC) federation.

```terraform
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
```

## Secret Provider Class

This creates a SecretProviderClass that instructs Kubernetes’s CSI driver how to mount secrets from Azure Key Vault into OTEL Collector pods. It references the managed identity, vault name, and the specific secret objects to expose at runtime.

```terraform
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
```

## Deploy OTEL Collector with Secrets

We deploy the OTEL Collector via Helm, enabling workload identity and mounting the CSI volume for secrets. Secrets are exposed in the pod at /mnt/secrets-store and injected as environment variables using extraEnvsFrom.

```terraform
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
    value = local.otel_collector.image_tag
    },{
    name = "mode"
    value = "daemonset" # modify as needed
    },{
    name = "serviceAccount.name"
    value = local.otel_collector.service_account_name
  }]
  depends_on = [
    kubernetes_manifest.secret_provider_class
  ]
}
```

## Configure OTEL Collector

After all infrastructure is provisioned, we configure the OTEL Collector to use the secrets (e.g., Datadog API key) via environment variables. These values are securely mounted into the pod from Azure Key Vault using the SecretProviderClass and CSI driver. This ensures sensitive credentials are not hardcoded in the configuration.

```yaml
connectors:
  datadog/connector: null
exporters:
  datadog/exporter:
    api:
      fail_on_invalid_key: true
      key: $${env:DATADOG_API_KEY}
      site: datadoghq.eu
```

## Optional: Dynamic Reload with Reloader

This annotation hooks into [Stakater Reloader](https://github.com/stakater/Reloader) so that whenever the Kubernetes Secret (populated from Azure Key Vault via the CSI driver) is updated - such as when you rotate keys in Key Vault - the Collector pod automatically restarts and picks up the new values. Without this, you’d need to manually roll or restart pods after every secret rotation in Azure Key Vault to ensure the OTEL Collector uses the latest credentials.

Prerequisite: You must have the Reloader Helm chart deployed in your cluster and your Azure Key Vault secrets already mounted into Kubernetes via the Secrets Store CSI Driver.

```terraform
resource "helm_release" "this" {
  ...
  name  = "annotations.secret\\.reloader\\.stakater\\.com/reload"
  value = local.otel_collector.secret_name
  ...
}
```