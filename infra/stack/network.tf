resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project}-vpc" }
}

# Public subnets: Fargate tasks with public IPv4 for outbound access (image
# pulls, logs, secrets). Inbound application traffic is limited by SGs.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  availability_zone_id    = var.availability_zone_ids[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false

  tags = { Name = "${var.project}-public-${var.availability_zone_ids[count.index]}", Tier = "public" }
}

# Private subnets: internal ALB, RDS and CloudFront VPC-origin ENIs. No route
# to the internet in either direction.
resource "aws_subnet" "private" {
  count                = 2
  vpc_id               = aws_vpc.main.id
  availability_zone_id = var.availability_zone_ids[count.index]
  cidr_block           = cidrsubnet(var.vpc_cidr, 8, count.index + 10)

  tags = { Name = "${var.project}-private-${var.availability_zone_ids[count.index]}", Tier = "private" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Explicit table with only the implicit local route.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-private" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# The default security group allows intra-group traffic; strip it so nothing
# can rely on it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-default-unused" }
}
