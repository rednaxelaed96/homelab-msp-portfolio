# Homelab MSP portfolio
 
Hands-on Azure infrastructure labs, built and documented as a portfolio for cloud infrastructure and MSP-style roles. Each lab is a self-contained build with its own architecture, IaC, and a running log of what broke and how I fixed it.
 
## Why this exists
 
I'm demonstrating operational skills, deploying managed services, wiring up observability, automating with infrastructure-as-code, and troubleshooting real incidents in a lab environment that mirrors production patterns rather than toy tutorials.
 
## Labs
 
- [**01 — Container Apps, Postgres, Redis, and observability**](01-container-observability/README.md)
  Azure Container Apps running a small API, backed by Postgres Flexible Server and Redis Cache, with Azure Monitor alerting and a Grafana dashboard. Provisioned via Bicep with a GitHub Actions pipeline.
## Conventions
 
- Resource naming: `rg-`, `vnet-`, `snet-`, `nsg-` prefixes by resource type
- Every lab's `logs/` folder documents issues in **symptom → diagnosis → resolution → skill demonstrated** format
- Infrastructure is defined as code and torn down between sessions to control cost
## Contact
 
[LinkedIn](www.linkedin.com/in/alexander-deal-104b47128)