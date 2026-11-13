---
date: 2026-11-13
showTableOfContents: true
title: "Limit hostnames per team on a shared Gateway with ValidatingAdmissionPolicy"
description: "Gateway API ListenerSet lets teams attach their own hostnames to a shared Gateway, but the API cannot restrict which ones. A ValidatingAdmissionPolicy with CEL closes that gap without extra components. Tested on AKS."
tags: ["Azure", "AKS", "Azure Kubernetes Service", "Gateway API", "ListenerSet", "Platform Engineering", "Admission Policy", "CEL"]
type: "post"
---

In my [last post](/posts/agc-listenerset-multi-team/) a platform team owns the Gateway and every application team attaches its own `ListenerSet` and `HTTPRoute`. The only control the platform team has is `allowedListeners`, which selects *namespaces*. Once a namespace is allowed, it can claim any hostname.

A conflict is contained, but nothing stops team-b from creating a listener for `api.team-a.example.com`. This post closes that gap with a built-in Kubernetes feature: a **ValidatingAdmissionPolicy** (CEL). No extra component (I also tried Gatekeeper, see below).

The full files and the recorded output are in [demo-agc-listenerset](https://github.com/jonas-budde/demo-agc-listenerset) (`hostname-policy/` and `docs/outputs-hostname-policy.txt`).

## What I tested

The policy only looks at the API objects, so no gateway controller is involved. I used a plain AKS 1.36.5 cluster with the Gateway API v1.7.0 standard CRDs, where `ListenerSet` is included. The same policy applies to AGC, but I did not run it against an AGC Gateway.

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

Team-a can use its own domain:

```text
$ kubectl apply -f 20-valid.yaml
listenerset.gateway.networking.k8s.io/team-a-listeners created
httproute.gateway.networking.k8s.io/team-a-route created
```

A wildcard inside the team domain (`*.team-a.example.com`) is accepted as well. Everything else is rejected at admission time:

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

The error is clear for the team:

```text
The listenersets "b-uses-a" is invalid: : ValidatingAdmissionPolicy 'team-hostnames' with binding 'team-hostnames' denied request: hostname not allowed in this namespace, must be team-b.example.com or end with .team-b.example.com
```

The repo has the output of every case, including the apply errors and the `kubectl get` results.

## What about Gatekeeper?

AKS ships Gatekeeper with the Azure Policy add-on, so I tried the same rule there (AKS 1.36.5, Gatekeeper v3.23.1). The Rego version is in the repo under `hostname-policy/gatekeeper/`.

- **You cannot apply your own ConstraintTemplate.** With the add-on enabled, `kubectl apply` is rejected: `This cluster is governed by Azure Policy. Policies must be created through Azure.`
- **The template has to go through an Azure Policy custom definition** (mode `Microsoft.Kubernetes.Data`) with the template embedded, plus an assignment. After the assignment it took about 15 minutes until the template and constraints showed up in the cluster.
- **No namespace labels.** I did not get the label-driven model working. Instead each team needs its own assignment with the namespace and domain as parameters. I did not test Gatekeeper's namespace sync with the add-on.
- **The result is the same for covered namespaces.** A foreign hostname, a wildcard outside the domain, a missing hostname, a lookalike suffix and an UPDATE to a foreign hostname were denied. The own domain and `*.team-a.example.com` were accepted.
- **Namespaces without an assignment are open.** The unlabeled `team-c` could create a ListenerSet, where the VAP denied it. Gatekeeper here is default allow, the VAP with a label is default deny.

I did not verify Gatekeeper's audit of objects that existed before the policy. That would be the one real advantage over a VAP, which only checks `CREATE` and `UPDATE`.

My take: if you already run Azure Policy for governance, Gatekeeper fits. For this one rule, the VAP is shorter, applies immediately and needs no per-team assignment. The output is in `docs/outputs-hostname-policy-gatekeeper.txt` in the repo.

## Limits

- The policy only validates `CREATE` and `UPDATE`. Objects that already exist are not checked, so apply it before you onboard teams or review existing ones.
- The label is the source of truth. Whoever can edit the namespace labels can change the allowed domain, so keep that permission with the platform team.
- This only covers hostnames. I did not test path restrictions. They are possible in CEL but get complicated quickly.
- Two teams with overlapping suffixes are not prevented. Hand out distinct domains.
- The `hostname-suffix` label name is my choice and not part of any standard.

## Takeaways

- `allowedListeners` controls *who* may attach. It does not control *what* they claim. A ValidatingAdmissionPolicy covers the second part with a few lines of CEL and no extra component.
- Deny a missing hostname explicitly, otherwise a catch-all slips through.
- Keep the rule next to the namespace: one label per team is easy to review in GitOps.
