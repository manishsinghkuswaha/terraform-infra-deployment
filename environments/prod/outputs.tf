output "vpc_id" { value = module.vpc.vpc_id }
output "nat_gateway_id" { value = module.vpc.nat_gateway_id }
output "workload_instance_id" { value = try(module.workload[0].instance_id, null) }
output "workload_private_ip" { value = try(module.workload[0].private_ip, null) }
output "monitoring_instance_id" { value = try(module.monitoring[0].instance_id, null) }
output "monitoring_private_ip" { value = try(module.monitoring[0].private_ip, null) }
