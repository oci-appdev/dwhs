# OCI DataWalk and Hyperscience POC Planning Meeting Notes

**Date:** October 7, 2026  
**POC target:** Complete technical validation by November 25, 2026  
**Scope:** OCI connectivity, separate Kubernetes environments, application installation, and technical testing. Full production migration and final ATO are outside this POC.

## Decisions and agreements

- Build **two separate OKE clusters**: one for DataWalk and one for Hyperscience. The applications will not share a cluster.
- Start with the **DataWalk development environment**. Test and production are not required for the initial POC.
- The POC is complete when the infrastructure is operational, the applications are installed, and agreed technical tests pass. A signed production ATO is not a POC completion criterion.
- Use **private OCI connectivity** through the existing FastConnect/DRG path. Routine application components will not require direct public Internet access.
- Administrators will connect from a **Windows jump box**. YubiKeys are required for administrators, not business users performing application testing.
- OCI access will be separated into **Administrator, Developer, and Operator** groups with least-privilege policies.
- Application container images must be security-scanned before being loaded into **OCI Container Registry (OCIR)**.
- OCI Object Storage may be used through its **S3-compatible API** where the application requires S3 access.
- Hold a **weekly status meeting** through the POC target date.
- The existing on-premises environments are expected to run in parallel during migration; the working estimate discussed was approximately six months, subject to the final migration plan.

## Preliminary technical sizing

### DataWalk

- Separate OKE cluster.
- Begin with approximately **three worker nodes**, with a possible increase to five as testing and data volume require.
- Preliminary storage estimate:
  - Approximately **1 TB of block storage per worker**.
  - Approximately **1 TB of Object Storage** for the initial environment.
- DataWalk packages are expected to be delivered as container images; cluster workers need private access to OCIR.
- Kubernetes versions **1.34 and 1.35** were reported as supported during the meeting. The exact version must be confirmed in writing before the build.

### Hyperscience

- Separate OKE cluster.
- GPU capacity remains based on the OCI **A10.2** direction, subject to final application-team validation.
- Final worker-node count, Kubernetes version, storage, GPU topology, and external dependencies remain open.
- A dedicated technical session with the Hyperscience application team is required before its cluster is built.

## Proposed build sequence

1. Finalize participant names, access roles, and security forms.
2. Issue YubiKeys to POC administrators.
3. Provision and validate the Windows jump box.
4. Validate routing, DNS, firewall rules, and private FastConnect/DRG connectivity.
5. Confirm subnet CIDRs and IP capacity for OKE nodes, pods, services, and load balancers.
6. Create OCI compartments, policies, quotas, budgets, Vault secrets, logging, and monitoring.
7. Create the DataWalk OKE cluster and CPU worker nodes.
8. Scan and publish DataWalk images to OCIR.
9. Install and configure DataWalk.
10. Perform smoke, functional, workflow, storage, performance, and security tests.
11. Validate Hyperscience requirements in a separate technical meeting.
12. Create the Hyperscience OKE cluster and required CPU/GPU node pools.
13. Install and test Hyperscience.
14. Record results and issue a **GO, CONDITIONAL GO, EXTEND, or NO-GO** recommendation.

## Action items

| Owner | Action |
|---|---|
| Project manager | Update the high-level schedule, assign owners and durations, and maintain the weekly cadence. |
| John / OCI infrastructure team | Build the OCI landing-zone components, compartments, policies, budgets, networking, jump box, and OKE foundations. |
| Network team | Validate CIDRs, routes, DNS, firewall rules, FastConnect/DRG paths, and required private endpoints. |
| Security / identity team | Process administrator forms, YubiKeys, OCI groups, least-privilege policies, and image-scanning requirements. |
| DataWalk team | Confirm Kubernetes version, worker sizing, storage, image delivery, installation method, test data, and acceptance criteria. |
| Hyperscience team | Confirm Kubernetes version, worker and GPU topology, storage, dependencies, image delivery, and acceptance criteria. |
| Application owners | Define POC success criteria and identify the users who will perform testing. |
| Oracle team | Review the infrastructure activities, sequencing, durations, and OKE design; provide guided implementation support. |

## Open questions and risks

- Confirm the exact Kubernetes version supported by each application and by the selected OKE release.
- Confirm Hyperscience node count, GPU scheduling model, storage, database, registry, and network dependencies.
- Confirm the final DataWalk block- and object-storage requirements using current environment measurements.
- Confirm OKE pod and service CIDRs do not overlap the enterprise network or the existing `10.2.32.0` range discussed during the meeting.
- Define measurable POC success criteria, including functional workflows, performance targets, security evidence, recoverability, and operational readiness.
- Determine the time required for image scanning and security approval; this may control the application installation start date.
- Replace or revise any prior runbook that describes Hyperscience as a standalone Podman deployment. The current direction is a dedicated OKE cluster.
- Production environments, final ATO, production cutover, and decommissioning are follow-on activities and must not be treated as part of the initial POC.

## Immediate next steps

- Schedule the Hyperscience technical validation session.
- Collect the POC participant list and map each person to the Administrator, Developer, or Operator role.
- Complete security forms and YubiKey distribution.
- Validate the high-level schedule with Oracle before the next weekly meeting.
- Have the DataWalk and Hyperscience application owners submit written success criteria.
