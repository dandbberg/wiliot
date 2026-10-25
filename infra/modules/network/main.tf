# Three tiers per AZ:
#   public    /24  NAT gateway only
#   private   /20  EKS nodes and pods (VPC CNI gives every pod a VPC IP, hence /20)
#   database  /24  RDS only; no route to the internet in either direction

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # RDS and EKS endpoints are resolved by DNS name
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index) # 10.40.0-2.0/24
  tags              = { Name = "${var.name}-public-${var.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 1) # 10.40.16/32/48.0/20
  tags              = { Name = "${var.name}-private-${var.azs[count.index]}", Tier = "private" }
}

resource "aws_subnet" "database" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 8) # 10.40.8-10.0/24
  tags              = { Name = "${var.name}-database-${var.azs[count.index]}", Tier = "database" }
}

# --- egress for the apps: one NAT gateway (cost shortcut; single-AZ egress) ---

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = var.name }
  depends_on    = [aws_internet_gateway.this]
}

# --- routing --------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

# Producers need Binance (wss://stream.binance.com); nodes need ECR and the EKS API.
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Deliberately no default route: only the VPC-local route exists, so the
# database tier can neither reach out nor be reached from outside the VPC.
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-database" }
}

resource "aws_route_table_association" "database" {
  count          = 3
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# --- NACL: the database tier talks only to the app tier ---------------------------
# Belt and braces with the RDS security group. NACLs are stateless, so replies to
# the apps (ephemeral ports) need their own outbound rule.

resource "aws_network_acl" "database" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.database[*].id
  tags       = { Name = "${var.name}-database" }
}

resource "aws_network_acl_rule" "db_in_postgres" {
  count          = 3
  network_acl_id = aws_network_acl.database.id
  rule_number    = 100 + count.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = aws_subnet.private[count.index].cidr_block
  from_port      = 5432
  to_port        = 5432
}

resource "aws_network_acl_rule" "db_out_replies" {
  count          = 3
  network_acl_id = aws_network_acl.database.id
  rule_number    = 100 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = aws_subnet.private[count.index].cidr_block
  from_port      = 1024
  to_port        = 65535
}
