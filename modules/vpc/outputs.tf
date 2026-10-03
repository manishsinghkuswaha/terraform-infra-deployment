output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_ids_by_az" { value = { for az, subnet in aws_subnet.public : az => subnet.id } }
output "private_subnet_ids_by_az" { value = { for az, subnet in aws_subnet.private : az => subnet.id } }
output "nat_gateway_id" { value = aws_nat_gateway.this.id }
