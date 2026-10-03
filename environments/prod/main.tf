module "vpc" {
  source             = "../../modules/vpc"
  name               = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.availability_zones
  tags               = local.common_tags
}
resource "aws_security_group" "monitoring" {
  name        = "${local.name_prefix}-monitoring-sg"
  description = "Private Prometheus/Grafana; admin uses SSM port forwarding."
  vpc_id      = module.vpc.vpc_id
  dynamic "ingress" {
    for_each = var.monitoring_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-monitoring-sg" })
}
resource "aws_security_group" "workload" {
  name        = "${local.name_prefix}-workload-sg"
  description = "Node Exporter allowed only from monitoring security group."
  vpc_id      = module.vpc.vpc_id
  dynamic "ingress" {
    for_each = var.enable_monitoring && var.enable_sample_workload ? [1] : []
    content {
      description     = "Prometheus scrape"
      from_port       = 9100
      to_port         = 9100
      protocol        = "tcp"
      security_groups = [aws_security_group.monitoring.id]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-workload-sg" })
}
module "workload" {
  count              = var.enable_sample_workload ? 1 : 0
  source             = "../../modules/ssm_ec2"
  name               = "${local.name_prefix}-node-exporter"
  ami_id             = data.aws_ssm_parameter.al2023_ami.value
  instance_type      = var.workload_instance_type
  subnet_id          = module.vpc.private_subnet_ids_by_az[local.availability_zones[0]]
  security_group_ids = [aws_security_group.workload.id]
  user_data          = file("${path.module}/../../modules/workload/node-exporter.sh.tftpl")
  tags               = local.common_tags
}
module "monitoring" {
  count              = var.enable_monitoring ? 1 : 0
  source             = "../../modules/ssm_ec2"
  name               = "${local.name_prefix}-monitoring"
  ami_id             = data.aws_ssm_parameter.al2023_ami.value
  instance_type      = var.monitoring_instance_type
  subnet_id          = module.vpc.private_subnet_ids_by_az[local.availability_zones[1]]
  security_group_ids = [aws_security_group.monitoring.id]
  user_data = templatefile("${path.module}/../../modules/monitoring/user-data.sh.tftpl", {
    prom_config = base64encode(templatefile("${path.module}/../../modules/monitoring/prometheus.yml.tftpl", {
      workload_private_ip = try(module.workload[0].private_ip, "127.0.0.1")
    }))
    datasource_config  = filebase64("${path.module}/../../modules/monitoring/grafana-datasource.yml")
    dashboard_provider = filebase64("${path.module}/../../modules/monitoring/dashboard-provider.yml")
    dashboard_json     = filebase64("${path.module}/../../modules/monitoring/dashboard.json")
  })
  tags = local.common_tags
}
resource "aws_cloudwatch_metric_alarm" "monitoring_status" {
  count               = var.enable_status_alarm && var.enable_monitoring ? 1 : 0
  alarm_name          = "${local.name_prefix}-monitoring-status-check"
  alarm_description   = "Optional example for EC2 instance status checks."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = module.monitoring[0].instance_id }
  tags                = local.common_tags
}
