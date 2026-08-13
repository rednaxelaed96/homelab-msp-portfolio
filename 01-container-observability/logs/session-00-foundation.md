---
layout: post
title: "Session 0: Foundation, resource group, networking, and a registry to build on"
date: 2026-08-11
---

Before any compute or data services, this lab needed a foundation to build everything else on top of: a resource group, a network with a deliberately restrictive starting point, and a registry to push images to. Short session, but every choice here is one later sessions depend on, worth documenting for that reason alone.

## Setup: foundation resources, reasoning for each choice

- **`rg-homelab-msp` in East US**: single resource group to scope this entire lab, makes teardown, cost tracking, and access review straightforward as the project grows across sessions.
- **`vnet-homelab` (`10.0.0.0/16`) with `snet-lab` (`10.0.0.0/24`)**: sized generously at the VNet level to leave room for additional subnets later without renumbering, while keeping the first subnet small and specific to this lab's initial compute needs.
- **`nsg-lab`, associated to `snet-lab`, with a default DenyAllInBound rule at priority 1000**: starts the network fully closed rather than fully open. Nothing in this lab needs inbound access yet, so nothing is allowed in until a later session has a specific, deliberate reason to open a specific port, security groups should start restrictive and get exceptions added, not start open and get exceptions removed.
- **`acrhomelabakd.azurecr.io`, Basic tier, default settings**: Basic is sufficient for a single-developer lab with low image throughput and no geo-replication need, no reason to pay for Standard or Premium tier features this project doesn't use.

No issues to log for this session, straightforward resource creation with no unexpected errors. Worth noting as its own kind of data point: not every session needs to be a troubleshooting story, sometimes the plan just works.

## What's next

Session 1 builds on this foundation directly: a Container Apps environment attached to `snet-lab`, and the first image pushed to `acrhomelabakd`.