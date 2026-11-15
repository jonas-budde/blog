---
date: 2026-11-13
showTableOfContents: true
title: "Limit hostnames per team on a shared Gateway with ValidatingAdmissionPolicy"
description: "Gateway API ListenerSet lets teams attach their own hostnames to a shared Gateway, but the API cannot restrict which ones. A ValidatingAdmissionPolicy with CEL closes that gap without extra components. Tested on AKS."
tags: ["Azure", "AKS", "Azure Kubernetes Service", "Gateway API", "ListenerSet", "Platform Engineering", "Admission Policy", "CEL"]
type: "post"
---

In my [last post](/posts/agc-listenerset-multi-team/) a platform team owns the Gateway and every application team attaches its own `ListenerSet` and `HTTPRoute`. The only control the platform team has is `allowedListeners`, which selects *namespaces*. Once a namespace is allowed, it can claim any hostname.

A conflict is contained, but nothing stops team-b from creating a listener for `api.team-a.example.com`. This post closes that gap with a built-in Kubernetes feature: a **ValidatingAdmissionPolicy** (CEL).

The full manifests are in [demo-agc-listenerset](https://github.com/jonas-budde/demo-agc-listenerset) (`hostname-policy/`).

## Setup

You need Kubernetes 1.30 or newer (ValidatingAdmissionPolicy is GA) and the Gateway API standard CRDs v1.5 or newer, which include `ListenerSet`. The policy only looks at API objects, so no gateway controller is required.

## The idea

Each team namespace gets a label with the domain it owns:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: team-a
  labels:
    hostname-suffix: team-a.example.com
```

The policy reads that label through `namespaceObject` and checks every hostname in `ListenerSet` and `HTTPRoute` objects:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: team-hostnames
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["gateway.networking.k8s.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["listenersets", "httproutes"]
  variables:
    - name: suffix
      expression: "has(namespaceObject.metadata.labels) && 'hostname-suffix' in namespaceObject.metadata.labels ? namespaceObject.metadata.labels['hostname-suffix'] : ''"
    - name: hostnames
      expression: >-
        object.kind == 'ListenerSet'
          ? object.spec.listeners.map(l, has(l.hostname) ? l.hostname : '')
          : (has(object.spec.hostnames) ? object.spec.hostnames : [''])
  validations:
    - expression: "variables.suffix != ''"
      message: "namespace has no hostname-suffix label, so it may not define hostnames"
    - expression: "variables.hostnames.all(h, h == variables.suffix || h.endsWith('.' + variables.suffix))"
      messageExpression: "'hostname not allowed in this namespace, must be ' + variables.suffix + ' or end with .' + variables.suffix"
```

A missing hostname becomes an empty string, so it fails the check. That matters because a listener or route without a hostname would match everything. The binding applies the policy to all namespaces except the system ones and `platform`:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: team-hostnames
spec:
  policyName: team-hostnames
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "kube-public", "kube-node-lease", "platform"]
```

The suffix check uses `'.' + suffix`, so `evil-team-b.example.com` does not pass as a match for `team-b.example.com`.

## Result

Team-a can use its own domain, including a wildcard inside it (`*.team-a.example.com`). Everything else is rejected at admission time:

| Case | Result |
|---|---|
| ListenerSet in team-b with `api.team-a.example.com` | denied |
| ListenerSet in team-b with `*.example.com` | denied |
| ListenerSet without hostname | denied |
| ListenerSet with `evil-team-b.example.com` | denied |
| ListenerSet in a namespace without the label | denied |
| HTTPRoute in team-b with `api.team-a.example.com` | denied |
| HTTPRoute without hostnames | denied |
| UPDATE of team-a's ListenerSet to a team-b hostname | denied |

{{< details summary="Show output" >}}
```text
$ kubectl apply -f 20-valid.yaml
listenerset.gateway.networking.k8s.io/team-a-listeners created
httproute.gateway.networking.k8s.io/team-a-route created

$ kubectl apply -f denied/01-listenerset-foreign-hostname.yaml
The listenersets "b-uses-a" is invalid: : ValidatingAdmissionPolicy 'team-hostnames' with binding 'team-hostnames' denied request: hostname not allowed in this namespace, must be team-b.example.com or end with .team-b.example.com
```
{{< /details >}}

## What about Gatekeeper?

AKS ships Gatekeeper with the Azure Policy add-on, so the same rule can be written in Rego (`hostname-policy/gatekeeper/` in the repo).

- **No direct ConstraintTemplate.** With the add-on enabled, `kubectl apply` of your own template is rejected: `This cluster is governed by Azure Policy. Policies must be created through Azure.`
- **Policy goes through Azure Policy.** The template is embedded in a custom policy definition (mode `Microsoft.Kubernetes.Data`) and assigned to the cluster. It took about 15 minutes until the template and constraints appeared in the cluster.
- **One assignment per team instead of a label.** The VAP reads the domain from the namespace label. The Rego input contains the namespace name but not its labels. Reading them needs Gatekeeper's data replication (referential constraints), which the Gatekeeper docs warn can run into race conditions. With Azure Policy managing Gatekeeper, the practical route is parameters: one assignment per team with `namespaces` and `suffix`. Onboarding a team means a new assignment instead of a label.
- **Same decisions in covered namespaces.** Foreign hostname, wildcard outside the domain, missing hostname, lookalike suffix and an UPDATE to a foreign hostname were denied. The own domain and `*.team-a.example.com` were accepted.
- **Default allow.** A namespace without an assignment (`team-c`) could create a ListenerSet, where the VAP denies it.
- **Audit of existing objects.** Gatekeeper audits resources periodically (every 60 seconds by default) and records violations in the constraint status, limited to 20 per constraint by default. Azure Policy shows them as compliance results. The VAP only evaluates requests, so this is the part Gatekeeper does better.

Gatekeeper fits if you already govern with Azure Policy and want reporting on existing objects. For this one rule the VAP is shorter, applies immediately and needs no per-team assignment.

## Limits

- The VAP only validates `CREATE` and `UPDATE`. Objects that already exist are not checked, so apply it before you onboard teams or review existing ones. Gatekeeper's audit covers that.
- The label is the source of truth. Whoever can edit the namespace labels can change the allowed domain, so keep that permission with the platform team.
- Two teams with overlapping suffixes are not prevented. Hand out distinct domains.
- Paths are not covered. The same approach works for paths, but it is harder. Paths are not part of the ListenerSet, they live in `HTTPRoute.spec.rules[].matches[].path`. A match has a type (`Exact`, `PathPrefix` or `RegularExpression`) and without any match the route defaults to a prefix match on `/`, which catches every request. A policy would have to deny missing matches, handle each type and could not reason about regular expressions, which are implementation-specific. `PathPrefix` matches whole segments, so a plain `startsWith('/team-a')` would wrongly allow `/team-a-admin`. Filters such as URL rewrites can also change the final path, and teams sharing one hostname need clear path ownership.

## Takeaways

- `allowedListeners` controls *who* may attach. It does not control *what* they claim. A ValidatingAdmissionPolicy covers the second part with a few lines of CEL and no extra component.
- Deny a missing hostname explicitly, otherwise a catch-all slips through.
- Keep the rule next to the namespace: one label per team is easy to review in GitOps.
