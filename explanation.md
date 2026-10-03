# Session 24: Terraform on AWS with Prometheus and Grafana

> A mentor's walkthrough of the complete classroom project: from the problem and design, through remote state and AWS deployment, to monitoring, GitHub, and cleanup.

**Project repository:** https://github.com/manishsinghkuswaha/terraform-session24-infra  
**AWS region:** ap-south-1 (Mumbai)  
**Deployment scope:** dev only. The prod configuration is for review; do not apply it in this class.

---

## 1. The problem we are solving

Imagine a team has a small application server. The team needs a repeatable way to create its AWS network and servers, see whether they are healthy, and inspect them without opening SSH or a public dashboard to the internet. The team also needs Terraform's record of the infrastructure to survive a laptop failure and to prevent two people from changing the same environment at once.

We use Terraform to create the network and two private EC2 instances. The workload instance runs Node Exporter, which reports operating-system metrics. Prometheus collects those metrics. Grafana turns the collected time series into dashboards. Engineers reach Prometheus and Grafana through AWS Systems Manager (SSM) port forwarding; the instances have no public IP and no inbound SSH rule. Terraform state is stored in an encrypted, versioned S3 bucket, with S3 lock files to coordinate Terraform runs.

This is a teaching-sized design, not a highly available production platform. It intentionally uses one NAT Gateway and one monitoring server so the flow is easy to see. Those are also single points of failure, and the NAT Gateway is usually the largest short-lived cost in this lab.

### Learning outcomes

By the end, students should be able to explain:

- Why a VPC, public subnet, private subnet, route table, and NAT Gateway are used.
- How a reusable Terraform module accepts inputs and returns outputs.
- How cidrsubnet, for_each, count, locals, conditionals, and dynamic blocks fit this project.
- Why remote state must be bootstrapped before an S3 backend can be initialized.
- How SSM replaces inbound SSH for this demonstration.
- How Node Exporter, Prometheus, PromQL, and Grafana fit together.
- What the included GitHub Actions workflow does today and how a later OIDC-based deployment would work.

## 2. Architecture: follow one metric

Follow the diagram from left to right: Terraform creates AWS resources; the workload exports metrics; Prometheus scrapes them; Grafana queries Prometheus; the engineer reaches the private monitoring server through SSM.

~~~mermaid
flowchart LR
    TF[Terraform on engineer laptop] -->|AWS API| VPC[VPC: 10.0.0.0/16]
    VPC --> PUB[Public subnets in two AZs]
    VPC --> PRIV[Private subnets in two AZs]
    PUB --> NAT[NAT Gateway]
    NAT --> OUT[Outbound downloads and SSM connectivity]
    PRIV --> APP[Private workload EC2: Node Exporter :9100]
    PRIV --> MON[Private monitoring EC2: Prometheus :9090, Grafana :3000]
    APP -->|Metrics; monitoring SG only| MON
    LAPTOP[Engineer laptop] -->|SSM port forwarding| MON
    MON --> PROM[Prometheus time-series database]
    PROM --> GRAF[Grafana dashboard]
    TF -->|State and lock file| S3[Versioned, SSE-KMS S3 backend]
~~~

**The important security boundary:** the public subnets contain networking components such as the NAT Gateway, but the EC2 instances are in private subnets with no public IP. The workload's port 9100 is accepted only from the monitoring security group. There is no SSH ingress. The engineer's AWS identity must be allowed to start SSM sessions; a private IP alone does not provide access.

### CIDR map

A CIDR block is a range of IP addresses. The VPC gives the project a large private range. We divide it into smaller subnets so AWS can place resources in different Availability Zones (AZs).

| Network | CIDR | Purpose |
|---|---|---|
| VPC | 10.0.0.0/16 | Private address space for the lab |
| Public subnet, AZ 1 | 10.0.0.0/24 | NAT Gateway and public routing |
| Public subnet, AZ 2 | 10.0.1.0/24 | Public subnet in the second AZ |
| Private subnet, AZ 1 | 10.0.100.0/24 | Private EC2 resources |
| Private subnet, AZ 2 | 10.0.101.0/24 | Private EC2 resources in the second AZ |

The private subnets route outbound internet-bound traffic through the NAT Gateway in a public subnet. The NAT Gateway lets a private instance reach services such as package registries or SSM endpoints while connections initiated from the public internet cannot directly reach that instance. NAT is not a firewall rule for application ingress; security groups still control which inbound traffic is allowed.

## 3. Before class: tools and access

The lab needs Terraform 1.10 or newer (for S3 lock-file support), AWS CLI v2, Git, and the AWS Session Manager plugin. The AWS default profile must identify the intended classroom account and have enough permissions to manage this project's VPC, NAT, EC2, IAM, S3, and KMS resources in ap-south-1. Students also need access to the private GitHub repository if they are to clone it.

Check the active AWS identity before making resources:

~~~bash
aws sts get-caller-identity --profile default
aws configure get region --profile default
terraform version
~~~

The first command should return the expected account and user or role identity. Stop if it is the wrong account. Setting a Terraform variable for a region does not by itself configure the AWS CLI profile used by SSM commands, so explicitly pass --region ap-south-1 to AWS CLI calls in this lab.

Never put AWS access keys, session tokens, Terraform state, generated plans, or local backend configuration in Git. The project's .gitignore excludes common state and plan files as well as backend.hcl; still inspect git status before committing.

## 4. Repository tour

~~~text
bootstrap-state/              Creates the remote-state bucket and KMS key using local state
environments/
  dev/                         Classroom environment to deploy
  prod/                        Example configuration; leave unapplied
modules/
  vpc/                         VPC, subnets, routes, NAT, and network rules
  ssm_instance_role/           IAM role and profile for managed SSM access
  ssm_ec2/                     Private EC2 instances
  workload/                    Node Exporter workload setup
  monitoring/                  Prometheus, Grafana, and dashboard setup
labs/count-vs-foreach/         Small Terraform language exercise
scripts/configure-backend.sh   Generates local backend config for the environment roots
.github/workflows/             Validation-only GitHub Actions workflow
README.md                      Short project overview and quick-start reference
~~~

A **root module** is the configuration Terraform runs from, for example environments/dev. A **child module** is a reusable group of resources called by that root, such as modules/vpc. The dev root passes values into modules; module outputs return useful values such as instance IDs or network IDs.

## 5. Phase A: create the remote-state backend

### Why is this a separate first step?

Terraform must contact the configured backend before it can store state there. Therefore, the bucket cannot be created by a configuration that already depends on that same bucket for its state: the dependency would be circular. bootstrap-state solves this by using local state just long enough to create the S3 bucket and KMS key. After that, the environment roots use the S3 backend.

The bootstrap configuration creates a private S3 bucket with versioning, server-side encryption using a customer-managed KMS key, and a policy requiring TLS. Public access is blocked. The environment backend uses use_lockfile = true, so Terraform coordinates operations with a lock object in S3. This project uses S3 lock files and does not configure the older DynamoDB locking option.

### Commands for a fresh, isolated class account

Run these from the repository root only when you are intentionally creating a new backend for this account or lab:

~~~bash
cd bootstrap-state
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=bootstrap.tfplan
terraform show bootstrap.tfplan
~~~

Read the plan carefully. Confirm the account, region, bucket name, KMS key, and expected resources. Review expected charges before applying. If they are correct:

~~~bash
terraform apply bootstrap.tfplan
cd ..
bash scripts/configure-backend.sh
~~~

The script creates local backend.hcl files for dev and prod. They contain backend configuration and are intentionally ignored by Git. Inspect the generated values before use.

### Important for this instructor's AWS account

The backend for the instructor's class has already been created and is being retained for the later GitHub Actions phase. **Do not apply bootstrap-state again in that same account.** If the backend already exists, use the matching generated backend.hcl or recreate that local file with the existing bucket and key values. If you clone the repository to a different machine, ignored local files such as backend configuration and local bootstrap state will not be present. Do not blindly create a second bucket or apply against a bucket that contains state you need.

Treat the backend as durable infrastructure. Destroying the dev environment does not require destroying this bucket. Backend teardown is separate and should happen only after confirming that no state is needed, migrating or backing it up, and safely removing every S3 object version and delete marker before deleting the bucket.

## 6. Phase B: initialize and deploy dev

Move into the dev root. Terraform commands must be run from this directory (or supplied with -chdir=environments/dev). Running plain terraform plan at the repository root gives “No configuration files” because Terraform expects .tf files in its current directory.

~~~bash
cd environments/dev
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
terraform plan -var-file=dev.tfvars -out=dev.tfplan
terraform show dev.tfplan
~~~

terraform init downloads providers and modules and connects this root to the S3 backend. If you previously ran terraform init -backend=false for offline validation, that did not initialize the requested S3 backend. Reinitialize against the real backend before planning or applying:

~~~bash
terraform init -reconfigure -backend-config=backend.hcl
~~~

terraform plan is a proposed change, not a deployment. Read it before approval. For this lab, expect one VPC, four subnets, route tables and routes, one NAT Gateway and an Elastic IP, security groups, IAM roles and instance profiles, and two private EC2 instances. The plan should not open SSH, assign public IPs to the instances, or expose Grafana or Prometheus to the public internet. Review the actual plan rather than relying only on this list.

Only after reviewing the plan and cost should the instructor create the AWS resources:

~~~bash
terraform apply dev.tfplan
~~~

Keep environments/prod unapplied in this session. It demonstrates how the same module can be configured with different environment values, but deploying a second environment adds resources and costs.

### Terraform concepts visible in this build

**cidrsubnet** divides a larger network into consistent smaller networks. For example:

~~~hcl
cidrsubnet("10.0.0.0/16", 8, 0)   # 10.0.0.0/24
cidrsubnet("10.0.0.0/16", 8, 1)   # 10.0.1.0/24
cidrsubnet("10.0.0.0/16", 8, 100) # 10.0.100.0/24
~~~

The final argument is the subnet's number within the larger address block. It does **not** mean “pick the last host address.” 0, 1, and 100 choose different /24 network blocks; they do not mean the individual hosts 10.0.0.0, 10.0.0.1, and 10.0.0.2.

**for_each** creates resources from a map or set and gives each resource a stable key, such as an AZ name. This is a good fit for named subnets: adding or reordering an AZ does not renumber every subnet instance. **count** creates indexed copies (resource[0], resource[1], …) and is useful for a genuinely optional single resource; this project uses it for an optional CloudWatch alarm. Reordering a list used with count can change which real object belongs to an index, so for_each is often safer for named things.

**A dynamic block** generates repeated nested configuration. Here it keeps security-group ingress rules compact while allowing the rule list to vary. **Locals and conditionals** give readable names to derived values and select settings such as environment-specific sizing or whether an optional resource is enabled.

**Workspaces** give one configuration multiple state instances. They do not automatically change IAM access, resource names, variables, or safety boundaries. This project uses separate dev and prod root directories and separate backend state keys instead, making environment configuration and state selection explicit.

Try the AWS-free language lab in labs/count-vs-foreach/ before applying cloud resources. It helps students see how Terraform addresses change when a list is reordered and why stable keys matter.

## 7. Phase C: verify monitoring

Wait for EC2 user data/cloud-init to finish and for both instances to appear as managed nodes in Systems Manager. Retrieve the monitoring instance ID from the dev root:

~~~bash
terraform output -raw monitoring_instance_id
~~~

Copy that instance ID. Open a terminal and keep this first SSM session running to forward Prometheus port 9090 to your own machine:

~~~bash
aws ssm start-session \
  --profile default \
  --region ap-south-1 \
  --target i-REPLACE_WITH_MONITORING_INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9090"],"localPortNumber":["9090"]}'
~~~

Visit http://localhost:9090/targets. The node target should become **UP**. If it is down, check in this order: is the workload registered in SSM; is Node Exporter running on port 9100; does the workload security group allow 9100 from the monitoring security group; can Prometheus reach the workload's private address; is the Prometheus target configured correctly; has enough time passed for a scrape?

In a second terminal, open another SSM session and keep it running for Grafana on port 3000:

~~~bash
aws ssm start-session \
  --profile default \
  --region ap-south-1 \
  --target i-REPLACE_WITH_MONITORING_INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
~~~

Visit http://localhost:3000. The isolated demo has initial credentials admin / admin; change the password at first login. Do not reuse this demo password outside the isolated classroom environment. The dashboard's Prometheus data source points to http://prometheus:9090 on the containers' private Docker network. Inside the Grafana container, localhost would refer to Grafana itself, which is why the service name is used.

### Read a few PromQL expressions

In Prometheus Graph or a Grafana panel, try:

~~~promql
up
~~~

up is a built-in scrape health metric. A value of 1 means Prometheus successfully scraped that target; 0 means that scrape failed.

~~~promql
node_memory_MemAvailable_bytes
~~~

This reports available memory in bytes. To show MiB instead, divide by 1024 * 1024:

~~~promql
node_memory_MemAvailable_bytes / 1024 / 1024
~~~

CPU utilization as a percentage over the last five minutes can be approximated by taking one minus the fraction of CPU time spent idle:

~~~promql
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
~~~

rate estimates the per-second change in a cumulative counter. Averaging the idle fraction across cores and subtracting it from 1 gives the busy fraction. Multiplying by 100 changes it to percent. In an almost-idle lab, expect a low, changing value rather than a constant number.

## 8. A small failure exercise

This makes the monitoring flow memorable: deliberately stop the exporter, observe the symptom, and restore service.

1. Get the workload ID from the dev root: terraform output -raw workload_instance_id.
2. Start an SSM shell session to the workload instance using the AWS console or aws ssm start-session --profile default --region ap-south-1 --target i-WORKLOAD_ID.
3. Stop just the Node Exporter container: sudo docker stop node-exporter.
4. Wait for a Prometheus scrape, then refresh /targets or run up{job="node"}. The node target should show DOWN / value 0; Grafana graphs for that target will have gaps.
5. Restore the exporter: sudo docker start node-exporter.
6. Wait for another scrape and confirm the target returns to UP / 1.

Ask students to narrate the chain: **exporter process → network and security group → Prometheus scrape → time-series query → Grafana panel**. A dashboard gap is useful evidence, but does not alone tell us the cause. Troubleshooting means checking each link.

## 9. GitHub: what is automated now, and what comes later

The project is in a private repository so students can review and clone the same code. The included GitHub Actions workflow is **validation-only**: it checks formatting and validates Terraform configuration without deploying AWS resources. Backend-free validation avoids needing production AWS credentials just to lint a pull request.

The planned later deployment phase should use GitHub's OpenID Connect (OIDC) identity to request short-lived AWS role credentials. A pull request can produce a plan for review; a protected GitHub environment can require human approval before an apply. IAM trust and permissions should be limited to the expected repository, environment, and state key. Do not store long-lived AWS access keys in GitHub secrets, and do not turn a validation workflow into an auto-apply workflow without explicit review and protections.

Typical local Git collaboration after changing code:

~~~bash
git status --short
git diff --check
git add <files-you-reviewed>
git commit -m "Describe the change"
git push
~~~

Inspect what is staged before committing; use git add on reviewed files rather than blindly adding generated state, plans, credentials, or local backend.hcl.

## 10. Cost and cleanup after the live class

A NAT Gateway has an hourly charge plus data processing; EC2 instances, EBS volumes, public IPv4, KMS usage, and data transfer may also cost money. Prices, taxes, offers, and account eligibility vary. Before class, use the AWS Pricing Calculator or current AWS pricing pages for ap-south-1, and check the account's billing dashboard. Do not assume the lab is free-tier eligible. Keep the demo running only as long as needed.

After the student demonstration, destroy the dev environment from environments/dev:

~~~bash
terraform destroy -var-file=dev.tfvars
~~~

Read the destroy plan and confirm the target account and environment before approving it. This removes the demo VPC, NAT Gateway, EC2 instances, and related environment resources tracked by that dev state. Then check the AWS console and billing view for remaining resources or charges. Keep the backend bucket and KMS key for the later Actions session. They have their own storage/key costs, but retaining them preserves remote state.

Do not run terraform destroy from bootstrap-state as part of ordinary lab cleanup. That is the separate backend stack. Removing it is a deliberate final teardown after state has been backed up or migrated and every version of every S3 object has been handled safely.

## 11. Interview-ready explanation

> “I built a modular Terraform lab in AWS. The dev root creates a VPC with public and private subnets in two Availability Zones. Private EC2 instances have no public IP or SSH ingress. They use an IAM instance profile to register with Systems Manager, and engineers use SSM sessions for shell access and local port forwarding. A workload runs Node Exporter; a private monitoring host runs Prometheus and Grafana. A security-group rule allows the exporter port only from the monitoring security group. Terraform state is stored in a versioned, SSE-KMS encrypted S3 bucket with S3 lock-file locking. The repository has separate dev and prod roots, but only dev is deployed. GitHub Actions currently validates code; a later deployment flow should use OIDC, least privilege, and a protected approval gate.”

### Common interview questions

**Why use remote state?**  
The state is shared and durable instead of living only on one engineer's laptop. Versioning helps recover prior object versions, and locking coordinates concurrent Terraform operations. State may contain sensitive values, so encryption, restricted access, and avoiding Git commits are essential.

**Why separate the backend bootstrap from the environment?**  
Terraform must have a backend before it can store the environment's state. The bucket therefore has to be created by a separate initial configuration with local state, avoiding a circular dependency.

**Why are there public subnets if the EC2 instances are private?**  
The NAT Gateway needs a public subnet and a route to an Internet Gateway. Private instances use the NAT for outbound connectivity without receiving public IP addresses. Public subnets do not imply that application servers are public.

**Why SSM instead of SSH?**  
The demo avoids opening port 22 or distributing SSH keys. Access is authorized through IAM and managed-node registration. SSM still needs correct instance IAM, network connectivity, the Session Manager plugin on the client, and permission for the operator to start the session.

**What does Node Exporter do?**  
It exposes host operating-system metrics over HTTP, commonly on port 9100. It does not store or graph metrics. Prometheus scrapes it; Grafana queries Prometheus.

**What does a Prometheus target marked DOWN tell you?**  
Prometheus could not scrape that target at the last attempt. Investigate whether the exporter is running, the target address and port are correct, routing works, and the security group allows traffic from the scraper. It identifies a failed scrape, not automatically the root cause.

**Why for_each for subnets?**  
The AZ name is a meaningful, stable key. Terraform can identify a subnet by that key, reducing unexpected address changes when entries are added or reordered. count is convenient for optional resources or anonymous identical copies, but numeric indices are less descriptive.

**Is this production highly available?**  
No. It is a classroom lab. One NAT Gateway and one monitoring instance are deliberate cost and complexity trade-offs and create failure points. A production design would assess multi-AZ egress, monitoring redundancy, backups, access controls, alerting, capacity, and recovery objectives.

## 12. Suggested teaching flow

1. Start with the problem: repeatable infrastructure, secure access, and visible service health.
2. Trace the architecture diagram and ask where public access is blocked.
3. Explain CIDRs and subnets with the table before opening Terraform files.
4. Show the backend bootstrap and explain why it uses local state first.
5. Run fmt, validate, and plan; ask students to predict resources before reading the plan.
6. Walk from root inputs into the VPC module and back out through outputs.
7. Apply dev, then verify SSM registration before debugging Prometheus.
8. Open the Prometheus target page, then Grafana; connect the dashboard to the PromQL expressions.
9. Stop Node Exporter briefly, observe the failure, and restore it.
10. Explain what the GitHub workflow validates and what OIDC/protected approval would add later.
11. Destroy dev together and confirm the backend remains available for the next session.

The goal is not merely to memorize Terraform commands. The goal is for each student to explain what a component does, what depends on it, how to verify it, and where to look when it fails.
