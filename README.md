# Session 24: Terraform, AWS, Prometheus, and Grafana

A practical, short-lived AWS lab joining Terraform infrastructure-as-code with host monitoring. Deploy only dev; prod is a separate root for code review and planning.

## Architecture

Laptop --(IAM-authorized SSM port forwarding)--> private monitoring EC2 (Prometheus :9090, Grafana :3000) --(TCP/9100, monitoring SG only)--> private workload EC2 (Node Exporter). Two AZs each have a public and private /24 subnet inside 10.0.0.0/16. One NAT Gateway provides private outbound access for SSM and image/package downloads. EC2 has no public address or SSH ingress. Grafana/Prometheus listen only on the monitoring host's loopback address and are reached through SSM tunnels.

This is a learning topology, not HA: one NAT and one monitoring host are failure points. Private subnets in the second AZ route through the NAT in the first AZ, which can incur cross-AZ charges.

## Layout

- bootstrap-state/: local-state bootstrap for a versioned, private, SSE-KMS S3 backend
- environments/dev and environments/prod: separate roots and state keys
- modules/vpc: for_each subnets and cidrsubnet address generation
- modules/ssm_instance_role and modules/ssm_ec2: least-privilege SSM access and private EC2
- modules/monitoring: Prometheus/Grafana provisioning and dashboard
- modules/workload: Node Exporter cloud-init
- labs/count-vs-foreach: AWS-free Terraform language lab
- .github/workflows: validation-only CI, no AWS access

## Requirements

Terraform >= 1.10, AWS CLI v2 with the default profile authorized for EC2, VPC/NAT, IAM, S3 and KMS in ap-south-1, Git, and AWS Session Manager plugin. Check identity first:

    aws sts get-caller-identity --profile default

Never place credentials in Terraform files or Git. Later GitHub deployment should use GitHub OIDC and a short-lived AWS role, never long-lived AWS keys.

## 1. Bootstrap the remote backend

The bucket must exist before an S3 backend can be initialized. Bootstrap uses local state, which is gitignored; protect and back it up.

    cd bootstrap-state
    terraform init
    terraform fmt -check -recursive
    terraform validate
    terraform plan -out=bootstrap.tfplan
    terraform show bootstrap.tfplan

Review the plan and AWS costs before creating the KMS key and bucket. After approval:

    terraform apply bootstrap.tfplan
    cd ..
    ./scripts/configure-backend.sh

This generates ignored backend.hcl files for dev and prod. Review those files, then retain the bucket and KMS key for later CI. The S3 backend uses encryption, versioning and use_lockfile=true. State operations get an S3 lock object; concurrent Terraform operations cannot modify the same state.

## 2. Plan and deploy dev

    cd environments/dev
    terraform init -backend-config=backend.hcl
    terraform fmt -check -recursive
    terraform validate
    terraform plan -var-file=dev.tfvars -out=dev.tfplan
    terraform show dev.tfplan

Inspect the plan: it should have one VPC, four subnets, a NAT/EIP and routes, two security groups, IAM roles/profiles, and two private instances. It should have no public EC2 IP, SSH ingress, or public monitoring port. Review the regional cost estimate before approval, then:

    terraform apply dev.tfplan

The prod root uses the same reusable modules with a different CIDR and sizing. Keep it unapplied for this class.

## 3. Verify Prometheus and Grafana

Wait for cloud-init and SSM registration. Get the monitoring instance id with:

    terraform output -raw monitoring_instance_id

Open a Prometheus tunnel (substitute the printed instance id):

    aws ssm start-session --profile default --region ap-south-1 --target i-REPLACE_ID --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["9090"],"localPortNumber":["9090"]}'

Open http://localhost:9090/targets. The node target should become UP. Useful PromQL:

    up
    node_memory_MemAvailable_bytes
    100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))

Expected: up is 1 for reachable targets; memory is in bytes; CPU returns a changing percentage. Open a second tunnel for Grafana:

    aws ssm start-session --profile default --region ap-south-1 --target i-REPLACE_ID --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'

Visit http://localhost:3000. The isolated demo uses initial Grafana login admin/admin and prompts for a password change. Change it on first login. IAM permission to start an SSM session is still required. The preconfigured Prometheus source uses http://prometheus:9090 on Docker's private network; localhost inside Grafana would point to Grafana itself. The Session 24 Host Overview dashboard includes CPU and memory panels.

### Failure exercise

Get the workload ID with terraform output -raw workload_instance_id, start an SSM shell session to it, then run sudo docker stop node-exporter. After a scrape, up{job="node"} becomes 0 and Grafana panels show gaps. Run sudo docker start node-exporter and verify the target returns UP. Trace exporter -> security group/network -> Prometheus scrape -> PromQL -> Grafana.

## Language concepts and interview framing

The VPC module keys subnets by AZ name with for_each. cidrsubnet("10.0.0.0/16", 8, 0) gives 10.0.0.0/24; netnums 100 and 101 give 10.0.100.0/24 and 10.0.101.0/24. The Node Exporter ingress is a dynamic block and the optional CloudWatch alarm uses count. for_each gives stable key identities; count uses numeric indexes and can shift when a list is reordered. The local lab demonstrates both.

Workspaces create separate state instances of one configuration, but do not change its access policy, variables, or safety boundaries. This project uses separate root directories and backend keys for dev and prod, which are easier to inspect and protect.

Interview summary: Terraform builds a two-AZ VPC; private EC2 uses an instance profile for SSM instead of inbound SSH. One NAT gives outbound bootstrap access. Node Exporter exposes host metrics on 9100, allowed only from the Prometheus SG. Prometheus scrapes and stores them; Grafana queries Prometheus and is reached using SSM forwarding. Remote state is versioned, SSE-KMS encrypted, and protected from concurrent runs using S3 lock files.

## Cost and cleanup

NAT is the largest steady hourly cost. AWS's VPC pricing page lists about $0.19 per NAT Gateway-hour for Mumbai; 730 hours would be about $138.70 before processing/data transfer. The two EC2 instances, gp3 volumes, NAT public IPv4 and KMS key add charges. Docker pulls add NAT traffic. Rates, taxes, discounts and account offers can change; review AWS Pricing Calculator and billing immediately before class. This is not guaranteed to be free-tier eligible.

After class, destroy only the dev environment:

    cd environments/dev
    terraform destroy -var-file=dev.tfvars

Confirm NAT, EIP, EC2 and VPC resources are gone. Retain S3/KMS for the later Actions phase. S3 versions and the customer-managed KMS key continue to incur charges. Retire the backend separately only after safely migrating state, emptying all bucket object versions/delete markers and destroying the bootstrap root.

## GitHub phases

The included GitHub Actions workflow runs fmt and backend-free validation only. Later add GitHub OIDC trust, a plan workflow and a manually approved apply job behind a protected dev environment. Scope IAM to the repository and state key. Do not store AWS keys in GitHub secrets.
